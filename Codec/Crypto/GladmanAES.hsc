-- | ECB AES operation.  This code is based on the "AES" package from
-- Svein Ove Aas (University of Tromsø), though it is heavily modified
-- and any bugs should be blamed on me, Thomas M. DuBuisson.
{-# LANGUAGE FlexibleInstances, EmptyDataDecls, FlexibleContexts, 
    ForeignFunctionInterface, ViewPatterns #-}
{-# CFILES cbits/gladman/aescrypt.c cbits/gladman/aeskey.c cbits/gladman/aestab.c cbits/gladman/aes_modes.c #-}
module Codec.Crypto.GladmanAES
	( AES
	, N128, N192, N256
	, module Crypto.Classes
	, module Crypto.Modes) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as BI
import Crypto.Modes
import Crypto.Classes
import Crypto.Types
import Data.Tagged
import Data.Serialize

import Foreign
import Control.Applicative
import Control.Monad

#include "gladman/aesopt.h"
#include "gladman/aes.h"
#include "gladman/aestab.h"
#include "gladman/brg_endian.h"
#include "gladman/ctr_inc.h"

data N128
data N192
data N256

data AES n = AES
		{ encCtx :: EncryptCtxP
		, decCtx :: DecryptCtxP
		, aesKeyRaw :: B.ByteString }

-- | Create an encryption/decryption context for incremental
-- encryption/decryption
--
-- You may create an ECB context this way, in which case you may pass
-- undefined for the IV
newCtx :: B.ByteString -> IO (AES n)
newCtx key = do
	e <- (encryptCtx key)
	d <- (decryptCtx key)
	return $ AES e d key

instance BlockCipher (AES N128) where
	blockSize = Tagged 128
	encryptBlock = aesEnc
	decryptBlock = aesDec
	buildKey = aesBK 128
	keyLength = aesKL

instance BlockCipher (AES N192) where
	blockSize = Tagged 128
	encryptBlock = aesEnc
	decryptBlock = aesDec
	buildKey = aesBK 192
	keyLength = aesKL

instance BlockCipher (AES N256) where
	blockSize = Tagged 128
	encryptBlock = aesEnc
	decryptBlock = aesDec
	buildKey = aesBK 256
	keyLength = aesKL


aesEnc :: AES n -> B.ByteString -> B.ByteString
aesEnc k m = unsafePerformIO $ call _aes_ecb_encrypt (encCtx k) m

aesDec :: AES n -> B.ByteString -> B.ByteString
aesDec k m = unsafePerformIO $ call _aes_ecb_decrypt (decCtx k) m

aesBK :: Int -> B.ByteString -> Maybe (AES n)
aesBK n bs
  | B.length bs == n `div` 8 = Just $ unsafePerformIO (newCtx bs)
  | otherwise                = Nothing

aesKL :: AES n -> BitLength
aesKL = (*8) . B.length . aesKeyRaw

instance Serialize (AES N128) where
	get = getGeneral 16
	put = putByteString . aesKeyRaw

instance Serialize (AES N192) where
	get = getGeneral 24
	put = putByteString . aesKeyRaw

instance Serialize (AES N256) where
	get = getGeneral 32
	put = putByteString . aesKeyRaw

getGeneral :: BlockCipher (AES n) => Int -> Get (AES n)
getGeneral n = do
	bs <- getByteString n
	case buildKey bs of
		Nothing -> fail "Could not build key from serialized bytestring"
		Just x  -> return x

call :: (Ptr b -> Ptr Word8 -> Int -> Ptr a -> IO Int)
       -> ForeignPtr a -> B.ByteString -> IO B.ByteString
call f ctx (BI.toForeignPtr -> (bs,offset,len)) =
  withForeignPtr ctx $ \ctxp ->
  withForeignPtr bs $ \bsp ->
  BI.create len $ \obuf ->
  ensure $ f (bsp `plusPtr` offset) obuf len ctxp

foreign import ccall unsafe "aes_ecb_encrypt" _aes_ecb_encrypt
  :: Ptr Word8 -> Ptr Word8 -> Int -> Ptr EncryptCtxStruct -> IO Int
foreign import ccall unsafe "aes_ecb_decrypt" _aes_ecb_decrypt
  :: Ptr Word8 -> Ptr Word8 -> Int -> Ptr DecryptCtxStruct -> IO Int

type EncryptCtxP = ForeignPtr EncryptCtxStruct

type DecryptCtxP = ForeignPtr DecryptCtxStruct

data EncryptCtxStruct
instance Storable EncryptCtxStruct where
  sizeOf _ = #size aes_encrypt_ctx
  alignment _ = 16 -- FIXME: Maybe overkill, maybe underkill, definitely iffy

data DecryptCtxStruct
instance Storable DecryptCtxStruct where
  sizeOf _ = #size aes_decrypt_ctx
  alignment _ = 16

wrap :: Int -> Bool
wrap r | r == (#const EXIT_SUCCESS) = True
       | otherwise = False

ensure :: IO Int -> IO ()
ensure act = do
  r <- wrap <$> act
  unless r (fail "AES function failed")

foreign import ccall unsafe "aes_encrypt_key" _aes_encrypt_key 
  :: Ptr Word8 -> Int -> Ptr EncryptCtxStruct -> IO Int

encryptCtx :: B.ByteString -> IO EncryptCtxP
encryptCtx bs = do
  ctx <- mallocForeignPtr
  let (key,offset,len) = BI.toForeignPtr bs
  withForeignPtr ctx $ \ctx' ->
    withForeignPtr key $ \key' ->
    ensure $ _aes_encrypt_key (key' `plusPtr` offset) len ctx'
  return ctx

foreign import ccall unsafe "aes_decrypt_key" _aes_decrypt_key 
  :: Ptr Word8 -> Int -> Ptr DecryptCtxStruct -> IO Int

decryptCtx :: B.ByteString -> IO DecryptCtxP
decryptCtx bs = do
  ctx <- mallocForeignPtr
  let (key,offset,len) = BI.toForeignPtr bs
  withForeignPtr ctx $ \ctx' ->
    withForeignPtr key $ \key' ->
    ensure $ _aes_decrypt_key (key' `plusPtr` offset) len ctx'
  return ctx
