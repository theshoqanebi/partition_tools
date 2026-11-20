# Build lpmake, lpadd, lpflash, lpunpack and lpdump as static binaries.
#
#   make          build everything into bin/
#   make -j8      parallel build
#   make clean    delete build/ and bin/
#   make ANDROID=1  cross-build for Android with the NDK (see below)
#
# Override tools on the command line, e.g. `make CC=gcc CXX=g++`.

CC      := clang
CXX     := clang++
AR      := ar
STRIP   := strip
CFLAGS  := -static

ifeq ($(OS),Windows_NT)
  WINDOWS := 1
  # The recipes need a POSIX shell (sh, mkdir -p, printf, rm). Use Git Bash or
  # MSYS2, or put Git's usr/bin directory on PATH.
  ifeq ($(shell sh -c "echo ok"),)
    $(error No POSIX shell found: run make from Git Bash/MSYS2, or add Git's usr/bin to PATH)
  endif
else
  UNAME_S := $(shell uname -s)
  ARCH    := $(shell uname -m)
  ifeq ($(filter Linux Darwin,$(UNAME_S)),)
    WINDOWS := 1
  endif
endif

# ---- Android (NDK) cross build ----
#   make ANDROID=1                          arm64-v8a, API 30
#   make ANDROID=1 ANDROID_ABI=x86_64       also: armeabi-v7a, x86
#   make ANDROID=1 ANDROID_API=33
# The NDK is taken from ANDROID_NDK_HOME / ANDROID_NDK_ROOT, or the newest
# one under $ANDROID_HOME/ndk (or %LOCALAPPDATA%/Android/Sdk/ndk on Windows).
ifdef ANDROID
  ANDROID_ABI ?= arm64-v8a
  ANDROID_API ?= 30
  ifeq ($(ANDROID_ABI),arm64-v8a)
    ARCH := aarch64
    NDK_TRIPLE := aarch64-linux-android
  else ifeq ($(ANDROID_ABI),armeabi-v7a)
    ARCH := arm
    NDK_TRIPLE := armv7a-linux-androideabi
  else ifeq ($(ANDROID_ABI),x86_64)
    ARCH := x86_64
    NDK_TRIPLE := x86_64-linux-android
  else ifeq ($(ANDROID_ABI),x86)
    ARCH := i686
    NDK_TRIPLE := i686-linux-android
  else
    $(error Unsupported ANDROID_ABI '$(ANDROID_ABI)': use arm64-v8a, armeabi-v7a, x86_64 or x86)
  endif
  ifeq ($(OS),Windows_NT)
    NDK_HOST := windows-x86_64
    NDK_SDK  := $(or $(ANDROID_HOME),$(ANDROID_SDK_ROOT),$(subst \,/,$(LOCALAPPDATA))/Android/Sdk)
  else ifeq ($(UNAME_S),Darwin)
    NDK_HOST := darwin-x86_64
    NDK_SDK  := $(or $(ANDROID_HOME),$(ANDROID_SDK_ROOT),$(HOME)/Library/Android/sdk)
  else
    NDK_HOST := linux-x86_64
    NDK_SDK  := $(or $(ANDROID_HOME),$(ANDROID_SDK_ROOT),$(HOME)/Android/Sdk)
  endif
  ANDROID_NDK := $(or $(ANDROID_NDK_HOME),$(ANDROID_NDK_ROOT),$(lastword $(sort $(wildcard $(NDK_SDK)/ndk/*))))
  ifeq ($(ANDROID_NDK),)
    $(error NDK not found: set ANDROID_NDK_HOME)
  endif
  NDK_BIN := $(ANDROID_NDK)/toolchains/llvm/prebuilt/$(NDK_HOST)/bin
  CC      := $(NDK_BIN)/$(NDK_TRIPLE)$(ANDROID_API)-clang
  CXX     := $(NDK_BIN)/$(NDK_TRIPLE)$(ANDROID_API)-clang++
  AR      := $(NDK_BIN)/llvm-ar
  STRIP   := $(NDK_BIN)/llvm-strip
  # Target is Android, whatever the host is.
  WINDOWS :=
  # bionic has no PAGE_SIZE and libc++ dropped std::unary_function.
  CFLAGS  += -DPAGE_SIZE=4096 -D_LIBCPP_ENABLE_CXX17_REMOVED_UNARY_BINARY_FUNCTION
endif

ifdef WINDOWS
  LDFLAGS := -lws2_32
  EXE := .exe
endif

ifdef ANDROID
  BUILD := build/android-$(ANDROID_ABI)
  BIN   := bin/android-$(ANDROID_ABI)
else
  BUILD := build
  BIN   := bin
endif
LIBS  := $(BUILD)/lib
L     := lib
TOOLS := lpmake lpadd lpflash lpunpack lpdump
ifdef ANDROID
  # lpdump's on-device code needs fs_mgr and libsnapshot, which are not in lib/.
  TOOLS := $(filter-out lpdump,$(TOOLS))
endif

# Quiet, kernel-style output by default; use `make V=1` to see full commands.
ifeq ($(V),1)
  Q :=
  log =
else
  Q := @
  log = @printf '  %-7s %s\n' $(1) $(2)
endif

.PHONY: all clean
all: $(addsuffix $(EXE),$(addprefix $(BIN)/,$(TOOLS)))

# $(call define_lib,<name>,<archive>,<srcdir>,<compile flags>,<sources relative to srcdir>)
# Defines object rules and the archive rule for one static library.
define define_lib
$(1)_OBJS := $$(patsubst %,$(BUILD)/$(1)/%.o,$(5))
$$(LIBS)/$(2): $$($(1)_OBJS)
	@mkdir -p $$(@D)
	$$(call log,AR,$$@)
	$$(Q)$$(AR) rcs $$@ $$^
$$($(1)_OBJS): $(BUILD)/$(1)/%.o: $(3)/%
	@mkdir -p $$(@D)
	$$(call log,$$(if $$(filter %.c %.S,$$<),CC,CXX),$$<)
	$$(Q)$$(if $$(filter %.c %.S,$$<),$$(CC),$$(CXX)) $(4) $$(CFLAGS) -MMD -MP -c $$< -o $$@
-include $$($(1)_OBJS:.o=.d)
endef

# ---- liblog ----
ifndef WINDOWS
  liblog_extra := event_tag_map.cpp
endif
ifdef ANDROID
  # On Android, liblog also talks to logd and pmsg.
  liblog_extra += logd_writer.cpp pmsg_writer.cpp
endif
liblog_src := log_event_list.cpp log_event_write.cpp logger_name.cpp logger_read.cpp logger_write.cpp logprint.cpp properties.cpp $(liblog_extra)
$(eval $(call define_lib,liblog,liblog.a,$(L)/liblog,-std=c++17 -I$(L)/include -I$(L)/liblog/include -I$(L)/base/include -DLIBLOG_LOG_TAG=1006 -DSNET_EVENT_LOG_TAG=1397638484,$(liblog_src)))

# ---- zlib ----
zlib_src := adler32.c compress.c cpu_features.c crc32.c deflate.c gzclose.c gzlib.c gzread.c gzwrite.c infback.c inflate.c inftrees.c inffast.c trees.c uncompr.c zutil.c
$(eval $(call define_lib,zlib,libz.a,$(L)/zlib,-I$(L)/zlib -O3 -DHAVE_HIDDEN -DZLIB_CONST,$(zlib_src)))

# ---- base ----
ifdef WINDOWS
  base_extra := errors_windows.cpp utf8.cpp
else
  base_extra := errors_unix.cpp
endif
base_src := abi_compatibility.cpp chrono_utils.cpp file.cpp liblog_symbols.cpp logging.cpp mapped_file.cpp parsebool.cpp parsenetaddress.cpp process.cpp properties.cpp stringprintf.cpp strings.cpp threads.cpp test_utils.cpp $(base_extra)
$(eval $(call define_lib,base,libbase.a,$(L)/base,-std=c++17 -I$(L)/include,$(base_src)))

# ---- libsparse ----
sparse_src := backed_block.cpp output_file.cpp sparse.cpp sparse_crc32.cpp sparse_err.cpp sparse_read.cpp
$(eval $(call define_lib,sparse,libsparse.a,$(L)/libsparse,-std=c++17 -I$(L)/include -I$(L)/zlib,$(sparse_src)))

# ---- fmtlib ----
$(eval $(call define_lib,fmtlib,fmtlib.a,$(L)/fmtlib,-std=c++20 -I$(L)/fmtlib/include,src/format.cc))

# ---- liblp ----
lp_src := builder.cpp images.cpp partition_opener.cpp property_fetcher.cpp reader.cpp utility.cpp writer.cpp
$(eval $(call define_lib,lp,liblp.a,$(L)/liblp,-std=c++17 -I$(L)/include -D_FILE_OFFSET_BITS=64,$(lp_src)))

# ---- ext4_utils ----
ext4_src := ext4_utils.cpp wipe.cpp ext4_sb.cpp
$(eval $(call define_lib,ext4,libext4_utils.a,$(L)/ext4_utils,-std=c++17 -I$(L)/include -fno-strict-aliasing,$(ext4_src)))

# ---- libcrypto_utils ----
$(eval $(call define_lib,cryptoutils,libcrypto_utils.a,$(L)/libcrypto_utils,-I$(L)/libcrypto_utils/include -I$(L)/boringssl/include,android_pubkey.c))

# ---- libcrypto (boringssl) ----
ifndef WINDOWS
  CRYPTO_DEFS :=
else
  CRYPTO_DEFS := -DOPENSSL_NO_ASM
endif

# Assembly sources, chosen by host OS and architecture.
crypto_asm :=
ifndef WINDOWS
  ifneq ($(filter arm%,$(ARCH)),)
crypto_asm := \
	linux-arm/crypto/chacha/chacha-armv4.S \
	linux-arm/crypto/fipsmodule/aes-armv4.S \
	linux-arm/crypto/fipsmodule/aesv8-armx32.S \
	linux-arm/crypto/fipsmodule/armv4-mont.S \
	linux-arm/crypto/fipsmodule/bsaes-armv7.S \
	linux-arm/crypto/fipsmodule/ghash-armv4.S \
	linux-arm/crypto/fipsmodule/ghashv8-armx32.S \
	linux-arm/crypto/fipsmodule/sha1-armv4-large.S \
	linux-arm/crypto/fipsmodule/sha256-armv4.S \
	linux-arm/crypto/fipsmodule/sha512-armv4.S \
	linux-arm/crypto/fipsmodule/vpaes-armv7.S \
	linux-arm/crypto/test/trampoline-armv4.S \
	src/crypto/curve25519/asm/x25519-asm-arm.S \
	src/crypto/poly1305/poly1305_arm_asm.S \

  else ifneq ($(filter aarch64 arm64,$(ARCH)),)
crypto_asm := \
	linux-aarch64/crypto/chacha/chacha-armv8.S \
	linux-aarch64/crypto/fipsmodule/aesv8-armx64.S \
	linux-aarch64/crypto/fipsmodule/armv8-mont.S \
	linux-aarch64/crypto/fipsmodule/ghash-neon-armv8.S \
	linux-aarch64/crypto/fipsmodule/ghashv8-armx64.S \
	linux-aarch64/crypto/fipsmodule/sha1-armv8.S \
	linux-aarch64/crypto/fipsmodule/sha256-armv8.S \
	linux-aarch64/crypto/fipsmodule/sha512-armv8.S \
	linux-aarch64/crypto/fipsmodule/vpaes-armv8.S \
	linux-aarch64/crypto/test/trampoline-armv8.S \

  else ifneq ($(filter i386 i686,$(ARCH)),)
crypto_asm := \
	linux-x86/crypto/chacha/chacha-x86.S \
	linux-x86/crypto/fipsmodule/aes-586.S \
	linux-x86/crypto/fipsmodule/aesni-x86.S \
	linux-x86/crypto/fipsmodule/bn-586.S \
	linux-x86/crypto/fipsmodule/co-586.S \
	linux-x86/crypto/fipsmodule/ghash-ssse3-x86.S \
	linux-x86/crypto/fipsmodule/ghash-x86.S \
	linux-x86/crypto/fipsmodule/md5-586.S \
	linux-x86/crypto/fipsmodule/sha1-586.S \
	linux-x86/crypto/fipsmodule/sha256-586.S \
	linux-x86/crypto/fipsmodule/sha512-586.S \
	linux-x86/crypto/fipsmodule/vpaes-x86.S \
	linux-x86/crypto/fipsmodule/x86-mont.S \
	linux-x86/crypto/test/trampoline-x86.S \

  else ifneq ($(filter x86_64 amd64,$(ARCH)),)
crypto_asm := \
	linux-x86_64/crypto/chacha/chacha-x86_64.S \
	linux-x86_64/crypto/cipher_extra/aes128gcmsiv-x86_64.S \
	linux-x86_64/crypto/cipher_extra/chacha20_poly1305_x86_64.S \
	linux-x86_64/crypto/fipsmodule/aes-x86_64.S \
	linux-x86_64/crypto/fipsmodule/aesni-gcm-x86_64.S \
	linux-x86_64/crypto/fipsmodule/aesni-x86_64.S \
	linux-x86_64/crypto/fipsmodule/ghash-ssse3-x86_64.S \
	linux-x86_64/crypto/fipsmodule/ghash-x86_64.S \
	linux-x86_64/crypto/fipsmodule/md5-x86_64.S \
	linux-x86_64/crypto/fipsmodule/p256-x86_64-asm.S \
	linux-x86_64/crypto/fipsmodule/p256_beeu-x86_64-asm.S \
	linux-x86_64/crypto/fipsmodule/rdrand-x86_64.S \
	linux-x86_64/crypto/fipsmodule/rsaz-avx2.S \
	linux-x86_64/crypto/fipsmodule/sha1-x86_64.S \
	linux-x86_64/crypto/fipsmodule/sha256-x86_64.S \
	linux-x86_64/crypto/fipsmodule/sha512-x86_64.S \
	linux-x86_64/crypto/fipsmodule/vpaes-x86_64.S \
	linux-x86_64/crypto/fipsmodule/x86_64-mont.S \
	linux-x86_64/crypto/fipsmodule/x86_64-mont5.S \
	linux-x86_64/crypto/test/trampoline-x86_64.S \
	src/crypto/hrss/asm/poly_rq_mul.S \

  endif
else
  ifneq ($(filter i386 i686,$(ARCH)),)
crypto_asm := \
	win-x86/crypto/chacha/chacha-x86.asm \
	win-x86/crypto/fipsmodule/aes-586.asm \
	win-x86/crypto/fipsmodule/aesni-x86.asm \
	win-x86/crypto/fipsmodule/bn-586.asm \
	win-x86/crypto/fipsmodule/co-586.asm \
	win-x86/crypto/fipsmodule/ghash-ssse3-x86.asm \
	win-x86/crypto/fipsmodule/ghash-x86.asm \
	win-x86/crypto/fipsmodule/md5-586.asm \
	win-x86/crypto/fipsmodule/sha1-586.asm \
	win-x86/crypto/fipsmodule/sha256-586.asm \
	win-x86/crypto/fipsmodule/sha512-586.asm \
	win-x86/crypto/fipsmodule/vpaes-x86.asm \
	win-x86/crypto/fipsmodule/x86-mont.asm \
	win-x86/crypto/test/trampoline-x86.asm \

  else ifneq ($(filter x86_64 amd64,$(ARCH)),)
crypto_asm := \
	win-x86_64/crypto/chacha/chacha-x86_64.asm \
	win-x86_64/crypto/cipher_extra/aes128gcmsiv-x86_64.asm \
	win-x86_64/crypto/cipher_extra/chacha20_poly1305_x86_64.asm \
	win-x86_64/crypto/fipsmodule/aes-x86_64.asm \
	win-x86_64/crypto/fipsmodule/aesni-gcm-x86_64.asm \
	win-x86_64/crypto/fipsmodule/aesni-x86_64.asm \
	win-x86_64/crypto/fipsmodule/ghash-ssse3-x86_64.asm \
	win-x86_64/crypto/fipsmodule/ghash-x86_64.asm \
	win-x86_64/crypto/fipsmodule/md5-x86_64.asm \
	win-x86_64/crypto/fipsmodule/p256-x86_64-asm.asm \
	win-x86_64/crypto/fipsmodule/p256_beeu-x86_64-asm.asm \
	win-x86_64/crypto/fipsmodule/rdrand-x86_64.asm \
	win-x86_64/crypto/fipsmodule/rsaz-avx2.asm \
	win-x86_64/crypto/fipsmodule/sha1-x86_64.asm \
	win-x86_64/crypto/fipsmodule/sha256-x86_64.asm \
	win-x86_64/crypto/fipsmodule/sha512-x86_64.asm \
	win-x86_64/crypto/fipsmodule/vpaes-x86_64.asm \
	win-x86_64/crypto/fipsmodule/x86_64-mont.asm \
	win-x86_64/crypto/fipsmodule/x86_64-mont5.asm \
	win-x86_64/crypto/test/trampoline-x86_64.asm \

  endif
endif

crypto_src := \
	err_data.c \
	src/crypto/asn1/a_bitstr.c \
	src/crypto/asn1/a_bool.c \
	src/crypto/asn1/a_d2i_fp.c \
	src/crypto/asn1/a_dup.c \
	src/crypto/asn1/a_enum.c \
	src/crypto/asn1/a_gentm.c \
	src/crypto/asn1/a_i2d_fp.c \
	src/crypto/asn1/a_int.c \
	src/crypto/asn1/a_mbstr.c \
	src/crypto/asn1/a_object.c \
	src/crypto/asn1/a_octet.c \
	src/crypto/asn1/a_print.c \
	src/crypto/asn1/a_strnid.c \
	src/crypto/asn1/a_time.c \
	src/crypto/asn1/a_type.c \
	src/crypto/asn1/a_utctm.c \
	src/crypto/asn1/a_utf8.c \
	src/crypto/asn1/asn1_lib.c \
	src/crypto/asn1/asn1_par.c \
	src/crypto/asn1/asn_pack.c \
	src/crypto/asn1/f_enum.c \
	src/crypto/asn1/f_int.c \
	src/crypto/asn1/f_string.c \
	src/crypto/asn1/tasn_dec.c \
	src/crypto/asn1/tasn_enc.c \
	src/crypto/asn1/tasn_fre.c \
	src/crypto/asn1/tasn_new.c \
	src/crypto/asn1/tasn_typ.c \
	src/crypto/asn1/tasn_utl.c \
	src/crypto/asn1/time_support.c \
	src/crypto/base64/base64.c \
	src/crypto/bio/bio.c \
	src/crypto/bio/bio_mem.c \
	src/crypto/bio/connect.c \
	src/crypto/bio/fd.c \
	src/crypto/bio/file.c \
	src/crypto/bio/hexdump.c \
	src/crypto/bio/pair.c \
	src/crypto/bio/printf.c \
	src/crypto/bio/socket.c \
	src/crypto/bio/socket_helper.c \
	src/crypto/bn_extra/bn_asn1.c \
	src/crypto/bn_extra/convert.c \
	src/crypto/buf/buf.c \
	src/crypto/bytestring/asn1_compat.c \
	src/crypto/bytestring/ber.c \
	src/crypto/bytestring/cbb.c \
	src/crypto/bytestring/cbs.c \
	src/crypto/bytestring/unicode.c \
	src/crypto/chacha/chacha.c \
	src/crypto/cipher_extra/cipher_extra.c \
	src/crypto/cipher_extra/derive_key.c \
	src/crypto/cipher_extra/e_aesccm.c \
	src/crypto/cipher_extra/e_aesctrhmac.c \
	src/crypto/cipher_extra/e_aesgcmsiv.c \
	src/crypto/cipher_extra/e_chacha20poly1305.c \
	src/crypto/cipher_extra/e_null.c \
	src/crypto/cipher_extra/e_rc2.c \
	src/crypto/cipher_extra/e_rc4.c \
	src/crypto/cipher_extra/e_tls.c \
	src/crypto/cipher_extra/tls_cbc.c \
	src/crypto/cmac/cmac.c \
	src/crypto/conf/conf.c \
	src/crypto/cpu-aarch64-fuchsia.c \
	src/crypto/cpu-aarch64-linux.c \
	src/crypto/cpu-arm-linux.c \
	src/crypto/cpu-arm.c \
	src/crypto/cpu-intel.c \
	src/crypto/cpu-ppc64le.c \
	src/crypto/crypto.c \
	src/crypto/curve25519/spake25519.c \
	src/crypto/dh/check.c \
	src/crypto/dh/dh.c \
	src/crypto/dh/dh_asn1.c \
	src/crypto/dh/params.c \
	src/crypto/digest_extra/digest_extra.c \
	src/crypto/dsa/dsa.c \
	src/crypto/dsa/dsa_asn1.c \
	src/crypto/ec_extra/ec_asn1.c \
	src/crypto/ec_extra/ec_derive.c \
	src/crypto/ecdh_extra/ecdh_extra.c \
	src/crypto/ecdsa_extra/ecdsa_asn1.c \
	src/crypto/engine/engine.c \
	src/crypto/err/err.c \
	src/crypto/evp/digestsign.c \
	src/crypto/evp/evp.c \
	src/crypto/evp/evp_asn1.c \
	src/crypto/evp/evp_ctx.c \
	src/crypto/evp/p_dsa_asn1.c \
	src/crypto/evp/p_ec.c \
	src/crypto/evp/p_ec_asn1.c \
	src/crypto/evp/p_ed25519.c \
	src/crypto/evp/p_ed25519_asn1.c \
	src/crypto/evp/p_rsa.c \
	src/crypto/evp/p_rsa_asn1.c \
	src/crypto/evp/p_x25519.c \
	src/crypto/evp/p_x25519_asn1.c \
	src/crypto/evp/pbkdf.c \
	src/crypto/evp/print.c \
	src/crypto/evp/scrypt.c \
	src/crypto/evp/sign.c \
	src/crypto/ex_data.c \
	src/crypto/fipsmodule/bcm.c \
	src/crypto/fipsmodule/fips_shared_support.c \
	src/crypto/fipsmodule/is_fips.c \
	src/crypto/hkdf/hkdf.c \
	src/crypto/hrss/hrss.c \
	src/crypto/lhash/lhash.c \
	src/crypto/mem.c \
	src/crypto/obj/obj.c \
	src/crypto/obj/obj_xref.c \
	src/crypto/pem/pem_all.c \
	src/crypto/pem/pem_info.c \
	src/crypto/pem/pem_lib.c \
	src/crypto/pem/pem_oth.c \
	src/crypto/pem/pem_pk8.c \
	src/crypto/pem/pem_pkey.c \
	src/crypto/pem/pem_x509.c \
	src/crypto/pem/pem_xaux.c \
	src/crypto/pkcs7/pkcs7.c \
	src/crypto/pkcs7/pkcs7_x509.c \
	src/crypto/pkcs8/p5_pbev2.c \
	src/crypto/pkcs8/pkcs8.c \
	src/crypto/pkcs8/pkcs8_x509.c \
	src/crypto/poly1305/poly1305.c \
	src/crypto/poly1305/poly1305_arm.c \
	src/crypto/poly1305/poly1305_vec.c \
	src/crypto/pool/pool.c \
	src/crypto/rand_extra/deterministic.c \
	src/crypto/rand_extra/forkunsafe.c \
	src/crypto/rand_extra/fuchsia.c \
	src/crypto/rand_extra/rand_extra.c \
	src/crypto/rand_extra/windows.c \
	src/crypto/rc4/rc4.c \
	src/crypto/refcount_c11.c \
	src/crypto/refcount_lock.c \
	src/crypto/rsa_extra/rsa_asn1.c \
	src/crypto/rsa_extra/rsa_print.c \
	src/crypto/siphash/siphash.c \
	src/crypto/stack/stack.c \
	src/crypto/thread.c \
	src/crypto/thread_none.c \
	src/crypto/thread_pthread.c \
	src/crypto/thread_win.c \
	src/crypto/x509/a_digest.c \
	src/crypto/x509/a_sign.c \
	src/crypto/x509/a_strex.c \
	src/crypto/x509/a_verify.c \
	src/crypto/x509/algorithm.c \
	src/crypto/x509/asn1_gen.c \
	src/crypto/x509/by_dir.c \
	src/crypto/x509/by_file.c \
	src/crypto/x509/i2d_pr.c \
	src/crypto/x509/rsa_pss.c \
	src/crypto/x509/t_crl.c \
	src/crypto/x509/t_req.c \
	src/crypto/x509/t_x509.c \
	src/crypto/x509/t_x509a.c \
	src/crypto/x509/x509.c \
	src/crypto/x509/x509_att.c \
	src/crypto/x509/x509_cmp.c \
	src/crypto/x509/x509_d2.c \
	src/crypto/x509/x509_def.c \
	src/crypto/x509/x509_ext.c \
	src/crypto/x509/x509_lu.c \
	src/crypto/x509/x509_obj.c \
	src/crypto/x509/x509_r2x.c \
	src/crypto/x509/x509_req.c \
	src/crypto/x509/x509_set.c \
	src/crypto/x509/x509_trs.c \
	src/crypto/x509/x509_txt.c \
	src/crypto/x509/x509_v3.c \
	src/crypto/x509/x509_vfy.c \
	src/crypto/x509/x509_vpm.c \
	src/crypto/x509/x509cset.c \
	src/crypto/x509/x509name.c \
	src/crypto/x509/x509rset.c \
	src/crypto/x509/x509spki.c \
	src/crypto/x509/x_algor.c \
	src/crypto/x509/x_all.c \
	src/crypto/x509/x_attrib.c \
	src/crypto/x509/x_crl.c \
	src/crypto/x509/x_exten.c \
	src/crypto/x509/x_info.c \
	src/crypto/x509/x_name.c \
	src/crypto/x509/x_pkey.c \
	src/crypto/x509/x_pubkey.c \
	src/crypto/x509/x_req.c \
	src/crypto/x509/x_sig.c \
	src/crypto/x509/x_spki.c \
	src/crypto/x509/x_val.c \
	src/crypto/x509/x_x509.c \
	src/crypto/x509/x_x509a.c \
	src/crypto/x509v3/pcy_cache.c \
	src/crypto/x509v3/pcy_data.c \
	src/crypto/x509v3/pcy_lib.c \
	src/crypto/x509v3/pcy_map.c \
	src/crypto/x509v3/pcy_node.c \
	src/crypto/x509v3/pcy_tree.c \
	src/crypto/x509v3/v3_akey.c \
	src/crypto/x509v3/v3_akeya.c \
	src/crypto/x509v3/v3_alt.c \
	src/crypto/x509v3/v3_bcons.c \
	src/crypto/x509v3/v3_bitst.c \
	src/crypto/x509v3/v3_conf.c \
	src/crypto/x509v3/v3_cpols.c \
	src/crypto/x509v3/v3_crld.c \
	src/crypto/x509v3/v3_enum.c \
	src/crypto/x509v3/v3_extku.c \
	src/crypto/x509v3/v3_genn.c \
	src/crypto/x509v3/v3_ia5.c \
	src/crypto/x509v3/v3_info.c \
	src/crypto/x509v3/v3_int.c \
	src/crypto/x509v3/v3_lib.c \
	src/crypto/x509v3/v3_ncons.c \
	src/crypto/x509v3/v3_ocsp.c \
	src/crypto/x509v3/v3_pci.c \
	src/crypto/x509v3/v3_pcia.c \
	src/crypto/x509v3/v3_pcons.c \
	src/crypto/x509v3/v3_pku.c \
	src/crypto/x509v3/v3_pmaps.c \
	src/crypto/x509v3/v3_prn.c \
	src/crypto/x509v3/v3_purp.c \
	src/crypto/x509v3/v3_skey.c \
	src/crypto/x509v3/v3_sxnet.c \
	src/crypto/x509v3/v3_utl.c \
	src/third_party/fiat/curve25519.c \

ifndef WINDOWS
crypto_src += $(crypto_asm)
endif

$(eval $(call define_lib,crypto,libcrypto.a,$(L)/boringssl,-I$(L)/boringssl/include -std=c99 $(CRYPTO_DEFS) -DBORINGSSL_IMPLEMENTATION -fvisibility=hidden -DBORINGSSL_SHARED_LIBRARY -DBORINGSSL_ANDROID_SYSTEM -DOPENSSL_SMALL -D_XOPEN_SOURCE=700,$(crypto_src)))

# ---- protobuf ----
protobuf_src := \
	src/google/protobuf/any_lite.cc \
	src/google/protobuf/arena.cc \
	src/google/protobuf/extension_set.cc \
	src/google/protobuf/generated_enum_util.cc \
	src/google/protobuf/generated_message_table_driven_lite.cc \
	src/google/protobuf/generated_message_util.cc \
	src/google/protobuf/implicit_weak_message.cc \
	src/google/protobuf/io/coded_stream.cc \
	src/google/protobuf/io/io_win32.cc \
	src/google/protobuf/io/strtod.cc \
	src/google/protobuf/io/zero_copy_stream.cc \
	src/google/protobuf/io/zero_copy_stream_impl.cc \
	src/google/protobuf/io/zero_copy_stream_impl_lite.cc \
	src/google/protobuf/message_lite.cc \
	src/google/protobuf/parse_context.cc \
	src/google/protobuf/repeated_field.cc \
	src/google/protobuf/stubs/bytestream.cc \
	src/google/protobuf/stubs/common.cc \
	src/google/protobuf/stubs/int128.cc \
	src/google/protobuf/stubs/status.cc \
	src/google/protobuf/stubs/statusor.cc \
	src/google/protobuf/stubs/stringpiece.cc \
	src/google/protobuf/stubs/stringprintf.cc \
	src/google/protobuf/stubs/structurally_valid.cc \
	src/google/protobuf/stubs/strutil.cc \
	src/google/protobuf/stubs/time.cc \
	src/google/protobuf/wire_format_lite.cc \
	src/google/protobuf/any.cc \
	src/google/protobuf/any.pb.cc \
	src/google/protobuf/api.pb.cc \
	src/google/protobuf/compiler/importer.cc \
	src/google/protobuf/compiler/parser.cc \
	src/google/protobuf/descriptor.cc \
	src/google/protobuf/descriptor.pb.cc \
	src/google/protobuf/descriptor_database.cc \
	src/google/protobuf/duration.pb.cc \
	src/google/protobuf/dynamic_message.cc \
	src/google/protobuf/empty.pb.cc \
	src/google/protobuf/extension_set_heavy.cc \
	src/google/protobuf/field_mask.pb.cc \
	src/google/protobuf/generated_message_reflection.cc \
	src/google/protobuf/generated_message_table_driven.cc \
	src/google/protobuf/io/gzip_stream.cc \
	src/google/protobuf/io/printer.cc \
	src/google/protobuf/io/tokenizer.cc \
	src/google/protobuf/map_field.cc \
	src/google/protobuf/message.cc \
	src/google/protobuf/reflection_ops.cc \
	src/google/protobuf/service.cc \
	src/google/protobuf/source_context.pb.cc \
	src/google/protobuf/struct.pb.cc \
	src/google/protobuf/stubs/mathlimits.cc \
	src/google/protobuf/stubs/substitute.cc \
	src/google/protobuf/text_format.cc \
	src/google/protobuf/timestamp.pb.cc \
	src/google/protobuf/type.pb.cc \
	src/google/protobuf/unknown_field_set.cc \
	src/google/protobuf/util/delimited_message_util.cc \
	src/google/protobuf/util/field_comparator.cc \
	src/google/protobuf/util/field_mask_util.cc \
	src/google/protobuf/util/internal/datapiece.cc \
	src/google/protobuf/util/internal/default_value_objectwriter.cc \
	src/google/protobuf/util/internal/error_listener.cc \
	src/google/protobuf/util/internal/field_mask_utility.cc \
	src/google/protobuf/util/internal/json_escaping.cc \
	src/google/protobuf/util/internal/json_objectwriter.cc \
	src/google/protobuf/util/internal/json_stream_parser.cc \
	src/google/protobuf/util/internal/object_writer.cc \
	src/google/protobuf/util/internal/proto_writer.cc \
	src/google/protobuf/util/internal/protostream_objectsource.cc \
	src/google/protobuf/util/internal/protostream_objectwriter.cc \
	src/google/protobuf/util/internal/type_info.cc \
	src/google/protobuf/util/internal/type_info_test_helper.cc \
	src/google/protobuf/util/internal/utility.cc \
	src/google/protobuf/util/json_util.cc \
	src/google/protobuf/util/message_differencer.cc \
	src/google/protobuf/util/time_util.cc \
	src/google/protobuf/util/type_resolver_util.cc \
	src/google/protobuf/wire_format.cc \
	src/google/protobuf/wrappers.pb.cc \

$(eval $(call define_lib,protobuf,libprotobuf-cpp-full.a,$(L)/protobuf,-std=c++17 -I$(L)/protobuf/src -I$(L)/protobuf/android -I$(L)/zlib -DHAVE_ZLIB=1,$(protobuf_src)))

# ---- libcutils (Android only, for android_get_control_file) ----
ifdef ANDROID
$(eval $(call define_lib,cutils,libcutils.a,$(L)/libcutils,-std=c++17 -I$(L)/include -I$(L)/libcutils,android_get_control_file.cpp))
endif

# ---- libjsonpb ----
$(eval $(call define_lib,jsonpb,libjsonpbparse.a,$(L)/libjsonpb,-std=c++17 -I$(L)/include -I$(L)/libjsonpb/parse/include,parse/jsonpb.cpp))

# ---- tools ----
PT := partition_tools

BASE_LIBS := $(addprefix $(LIBS)/,liblp.a libsparse.a libext4_utils.a libz.a libbase.a fmtlib.a liblog.a libcrypto_utils.a libcrypto.a)
ifdef ANDROID
  BASE_LIBS += $(LIBS)/libcutils.a
endif
LPDUMP_LIBS := $(addprefix $(LIBS)/,libjsonpbparse.a libprotobuf-cpp-full.a)

TOOL_FLAGS := -std=c++17 -I$(L)/include -I$(L)/fmtlib/include $(CFLAGS) -D_FILE_OFFSET_BITS=64
ifdef ANDROID
  # bionic has no libpthread (it is part of libc), and fmt needs C++20 char8_t.
  PTHREAD :=
  TOOL_FLAGS += -std=c++20
else
  PTHREAD := -lpthread
endif
ifdef WINDOWS
  TOOL_FLAGS += -std=c++20 -I$(L)/compat/win32 -include $(L)/compat/win32/binmode.h -DWIN32
endif

lpdump_src := $(PT)/lpdump.cc $(PT)/dynamic_partitions_device_info.pb.cc $(PT)/lpdump_host.cc

$(BIN)/lpdump$(EXE): $(lpdump_src) $(BASE_LIBS) $(LPDUMP_LIBS)
	@mkdir -p $(@D)
	$(call log,LD,$@)
	$(Q)$(CXX) $(TOOL_FLAGS) -o $@ $(lpdump_src) $(BASE_LIBS) $(LPDUMP_LIBS) $(PTHREAD) $(LDFLAGS)
	$(call log,STRIP,$@)
	$(Q)$(STRIP) $@

$(BIN)/%$(EXE): $(PT)/%.cc $(BASE_LIBS)
	@mkdir -p $(@D)
	$(call log,LD,$@)
	$(Q)$(CXX) $(TOOL_FLAGS) -o $@ $< $(BASE_LIBS) $(PTHREAD) $(LDFLAGS)
	$(call log,STRIP,$@)
	$(Q)$(STRIP) $@

clean:
	$(call log,CLEAN,$(BUILD) $(BIN))
	$(Q)$(RM) -r $(BUILD) $(BIN)
