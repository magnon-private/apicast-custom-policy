local ffi = require "ffi"
local C = ffi.C
local ffi_gc = ffi.gc
local ffi_new = ffi.new
local ffi_str = ffi.string
local ffi_cast = ffi.cast

local evp_macro = require "custom.openssl.include.evp"
local ctypes = require "custom.openssl.aux.ctypes"
local format_error = require("custom.openssl.err").format_error
local OPENSSL_10 = require("custom.openssl.version").OPENSSL_10
local OPENSSL_11 = require("custom.openssl.version").OPENSSL_11

local uchar_array = ctypes.uchar_array
local void_ptr = ctypes.void_ptr
local ptr_of_int = ctypes.ptr_of_int

local _M = {}
local mt = {__index = _M}

local cipher_ctx_ptr_ct = ffi.typeof('EVP_CIPHER_CTX*')

function _M.new(typ)
  if not typ then
    return nil, "cipher.new: expect type to be defined"
  end

  local ctx
  if OPENSSL_11 then
    ctx = C.EVP_CIPHER_CTX_new()
    ffi_gc(ctx, C.EVP_CIPHER_CTX_free)
  elseif OPENSSL_10 then
    ctx = ffi.new('EVP_CIPHER_CTX')
    C.EVP_CIPHER_CTX_init(ctx)
    ffi_gc(ctx, C.EVP_CIPHER_CTX_cleanup)
  end
  if ctx == nil then
    return nil, "cipher.new: failed to create EVP_CIPHER_CTX"
  end

  local dtyp = C.EVP_get_cipherbyname(typ)
  if dtyp == nil then
    return nil, string.format("cipher.new: invalid cipher type \"%s\"", typ)
  end

  local code = C.EVP_CipherInit_ex(ctx, dtyp, nil, "", nil, -1)
  if code ~= 1 then
    return nil, format_error("cipher.new")
  end

  return setmetatable({
    ctx = ctx,
    initialized = false,
    block_size = tonumber(C.EVP_CIPHER_CTX_block_size(ctx)),
    key_size = tonumber(C.EVP_CIPHER_CTX_key_length(ctx)),
    iv_size = tonumber(C.EVP_CIPHER_CTX_iv_length(ctx)),
  }, mt), nil
end

function _M.istype(l)
  return l and l.ctx and ffi.istype(cipher_ctx_ptr_ct, l.ctx)
end

function _M:init(key, iv, opts)
  opts = opts or {}
  if not key or #key ~= self.key_size then
    return false, string.format("cipher:init: incorrect key size, expect %d", self.key_size)
  end
  if not iv or #iv ~= self.iv_size then
    return false, string.format("cipher:init: incorrect iv size, expect %d", self.iv_size)
  end

  if C.EVP_CipherInit_ex(self.ctx, nil, nil, key, iv, opts.is_encrypt and 1 or 0) == 0 then
    return false, format_error("cipher:init")
  end

  if opts.no_padding then
    -- EVP_CIPHER_CTX_set_padding() always returns 1.
    C.EVP_CIPHER_CTX_set_padding(self.ctx, 0)
  end

  self.initialized = true

  return true
end

function _M:encrypt(key, iv, s, no_padding, aead_aad)
  local _, err = self:init(key, iv, {
    is_encrypt = true,
    no_padding = no_padding,
  })
  if err then
    return nil, err
  end
  if aead_aad then
    local _, err = self:update_aead_aad(aead_aad)
    if err then
      return nil, err
    end
  end
  return self:final(s)
end

function _M:decrypt(key, iv, s, no_padding, aead_aad, aead_tag)
  local _, err = self:init(key, iv, {
    is_encrypt = false,
    no_padding = no_padding,
  })
  if err then
    return nil, err
  end
  if aead_aad then
    local _, err = self:update_aead_aad(aead_aad)
    if err then
      return nil, err
    end
  end
  if aead_tag then
    local _, err = self:set_aead_tag(aead_tag)
    if err then
      return nil, err
    end
  end
  return self:final(s)
end

-- https://wiki.openssl.org/index.php/EVP_Authenticated_Encryption_and_Decryption
function _M:update_aead_aad(aad)
  if not self.initialized then
    return nil, "cipher:update_aead_aad: cipher not initalized, call cipher:init first"
  end

  local outl = ptr_of_int()
  if C.EVP_CipherUpdate(self.ctx, nil, outl, aad, #aad) ~= 1 then
    return false, format_error("cipher:update_aead_aad")
  end
  return true
end

function _M:get_aead_tag(size)
  if not self.initialized then
    return nil, "cipher:get_aead_tag: cipher not initalized, call cipher:init first"
  end

  size = size or self.key_size / 2
  if size > self.key_size then
    return nil, string.format("tag size %d is too large", size)
  end
  local buf = ffi_new(uchar_array, size)
  if C.EVP_CIPHER_CTX_ctrl(self.ctx, evp_macro.EVP_CTRL_AEAD_GET_TAG, size, buf) ~= 1 then
    return nil, format_error("cipher:get_aead_tag")
  end

  return ffi_str(buf, size)
end

function _M:set_aead_tag(tag)
  if not self.initialized then
    return nil, "cipher:set_aead_tag: cipher not initalized, call cipher:init first"
  end

  if type(tag) ~= "string" then
    return false, "cipher:set_aead_tag expect a string at #1"
  end
  local tag_void_ptr = ffi_cast(void_ptr, tag)
  if C.EVP_CIPHER_CTX_ctrl(self.ctx, evp_macro.EVP_CTRL_AEAD_SET_TAG, #tag, tag_void_ptr) ~= 1 then
    return false, format_error("cipher:set_aead_tag")
  end

  return true
end

function _M:update(...)
  if not self.initialized then
    return nil, "cipher:update: cipher not initalized, call cipher:init first"
  end

  local ret = {}
  local max_length = 0
  for _, s in ipairs({...}) do
    local len = #s
    if len > max_length then
      max_length = len
    end
  end
  if max_length == 0 then
    return nil
  end
  local out = ffi_new(uchar_array, max_length + self.block_size)
  local outl = ptr_of_int()
  for _, s in ipairs({...}) do
    if C.EVP_CipherUpdate(self.ctx, out, outl, s, #s) ~= 1 then
      return nil, format_error("cipher:update")
    end
    table.insert(ret, ffi_str(out, outl[0]))
  end
  return table.concat(ret, "")
end

function _M:final(s)
  local ret, err
  if s then
    ret, err = self:update(s)
    if err then
      return nil, err
    end
  end
  local outm = ffi_new(uchar_array, self.block_size)
  local outl = ptr_of_int()
  if C.EVP_CipherFinal(self.ctx, outm, outl) ~= 1 then
    return nil, format_error("cipher:final: EVP_CipherFinal")
  end
  return (ret or "") .. ffi_str(outm, outl[0])
end

function _M:derive(key, salt, count, md)
  if type(key) ~= "string" then
    return nil, nil, "cipher:derive: expect a string at #1"
  elseif salt and type(salt) ~= "string" then
    return nil, nil, "cipher:derive: expect a string at #2"
  elseif count then
    count = tonumber(count)
    if not count then
      return nil, nil, "cipher:derive: expect a number at #3"
    end
  elseif md and type(md) ~= "string" then
    return nil, nil, "cipher:derive: expect a string or nil at #4"
  end

  if salt then
    if #salt > 8 then
      ngx.log(ngx.WARN, "cipher:derive: salt is too long, truncate salt to 8 bytes")
      salt = salt:sub(0, 8)
    elseif #salt < 8 then
      ngx.log(ngx.WARN, "cipher:derive: salt is too short, padding with zero bytes to length")
      salt = salt .. string.rep('\000', 8 - #salt)
    end
  end

  local mdt = C.EVP_get_digestbyname(md or 'sha1')
  if mdt == nil then
    return nil, nil, string.format("cipher:derive: invalid digest type \"%s\"", md)
  end
  local cipt = C.EVP_CIPHER_CTX_cipher(self.ctx)
  local keyb = ffi_new(uchar_array, self.key_size)
  local ivb = ffi_new(uchar_array, self.iv_size)

  local size = C.EVP_BytesToKey(cipt, mdt, salt,
                                key, #key, count or 1,
                                keyb, ivb)
  if size == 0 then
    return nil, nil, format_error("cipher:derive: EVP_BytesToKey")
  end

  return ffi_str(keyb, size), ffi_str(ivb, self.iv_size)
end

return _M
