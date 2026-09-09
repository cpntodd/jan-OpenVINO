#!/usr/bin/env bash
# Stages jan-llama-worker and the ggml runtime into src-tauri/resources/bin.
# Backend modules must sit beside the worker: ggml searches the exe directory
# (ggml-backend-reg.cpp), and libggml/libggml-base resolve via $ORIGIN.
set -euo pipefail

# Positional first: cmd.exe has no `VAR=value command` prefix.
PROFILE="${1:-${JAN_ENGINE_PROFILE:-release}}"
PLUGIN_DIR="src-tauri/plugins/tauri-plugin-llamacpp"
TARGET_DIR="${CARGO_TARGET_DIR:-$PLUGIN_DIR/target}/$PROFILE"
DEST="src-tauri/resources/bin"

# MODULE libraries are `.so` on macOS too, and that is the only extension
# ggml's loader looks for there (no __APPLE__ case in backend_filename_extension).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) EXE=".exe"; LIBEXT="dll";   MODEXT="dll" ;;
  Darwin)               EXE="";     LIBEXT="dylib"; MODEXT="so"  ;;
  *)                    EXE="";     LIBEXT="so";    MODEXT="so"  ;;
esac

WORKER="$TARGET_DIR/jan-llama-worker$EXE"
if [ ! -f "$WORKER" ]; then
  echo "stage-engine: $WORKER not found; run the cargo build first" >&2
  exit 1
fi

mkdir -p "$DEST"

# The bundle globs ship whatever is in DEST, including an earlier variant's leftovers.
find "$DEST" -maxdepth 1 \( -name 'libggml*' -o -name 'ggml*.dll' \
  -o -name 'libcudart.so*' -o -name 'libcublas*.so*' \
  -o -name 'cudart64_*.dll' -o -name 'cublas*.dll' \
  -o -name 'libopenvino*.so*' -o -name 'libtbb*.so*' \
  -o -name 'libittnotify*.so*' -o -name 'openvino*.dll' \
  -o -name 'tbb*.dll' \) -exec rm -f {} +

install -m755 "$WORKER" "$DEST/jan-llama-worker$EXE"
echo "stage-engine: staged jan-llama-worker$EXE"

newest() {
  find "$TARGET_DIR/build" -maxdepth 3 "$@" -print0 2>/dev/null \
    | xargs -0 -r ls -dt 2>/dev/null | head -1 || true
}

# On Windows build.rs may relocate the cmake trees out of OUT_DIR (MAX_PATH)
# and leave the chosen root in a marker file.
PREFIX="$(newest -type d -name ggml-prefix)"
if [ -z "$PREFIX" ]; then
  MARKER="$(newest -type f -name engine-build-root.txt)"
  if [ -n "$MARKER" ]; then
    ROOT="$(tr -d '\r\n' < "$MARKER")"
    if command -v cygpath >/dev/null 2>&1; then
      ROOT="$(cygpath -u "$ROOT")"
    fi
    if [ -d "$ROOT/ggml-prefix" ]; then
      PREFIX="$ROOT/ggml-prefix"
    fi
  fi
fi
if [ -z "$PREFIX" ]; then
  echo "stage-engine: no ggml-prefix found under $TARGET_DIR/build" >&2
  echo "stage-engine: was the worker built with an engine-* feature?" >&2
  exit 1
fi

# cp -P keeps the libggml.so -> .so.0 -> .so.0.N.0 soname chain as links.
stage_lib() {
  local name
  name="$(basename "$1")"
  cp -Pf "$1" "$DEST/$name"
  [ -L "$1" ] || chmod 644 "$DEST/$name"
}

exts=("$LIBEXT")
[ "$MODEXT" = "$LIBEXT" ] || exts+=("$MODEXT")

srcs=()
for ext in "${exts[@]}"; do
  srcs+=("$PREFIX"/bin/*."$ext"* "$PREFIX"/lib/libggml*."$ext"*)
done

staged=0
modules=0
cuda_module=""
for src in "${srcs[@]}"; do
  [ -e "$src" ] || [ -L "$src" ] || continue
  stage_lib "$src"
  staged=$((staged + 1))
  case "$(basename "$src")" in
    libggml.*|libggml-base.*|ggml.dll|ggml-base.dll) ;;
    libggml-cuda.*|ggml-cuda.dll) modules=$((modules + 1)); cuda_module="$DEST/$(basename "$src")" ;;
    *) modules=$((modules + 1)) ;;
  esac
done

if [ "$staged" -eq 0 ]; then
  echo "stage-engine: found $PREFIX but no ggml libraries in it" >&2
  exit 1
fi

# The two core libraries alone make `staged` non-zero.
if [ "$modules" -eq 0 ]; then
  echo "stage-engine: staged $staged ggml libraries but no backend module" >&2
  echo "stage-engine: expected *.$MODEXT MODULE libraries in $PREFIX/bin" >&2
  exit 1
fi

echo "stage-engine: staged $staged ggml libraries ($modules backend modules) into $DEST"

# OpenVINO is a dynamically loaded ggml backend. The backend module itself is
# staged above, but its OpenVINO runtime and plugin libraries are not part of
# the llama.cpp build tree. Copy the runtime beside the worker so a packaged
# Jan process does not depend on a GUI-launched shell having sourced
# setupvars.sh. OpenVINO_DIR points at runtime/cmake in the archive layout.
openvino_module=""
for candidate in "$DEST"/libggml-openvino.* "$DEST"/ggml-openvino.dll; do
  if [ -e "$candidate" ] || [ -L "$candidate" ]; then
    openvino_module="$candidate"
    break
  fi
done

if [ -n "$openvino_module" ]; then
  [ -n "${OpenVINO_DIR:-}" ] || {
    echo "stage-engine: ggml-openvino was built but OpenVINO_DIR is unset" >&2
    exit 1
  }
  ov_runtime="$(cd "$(dirname "$OpenVINO_DIR")" && pwd)"
  [ -d "$ov_runtime" ] || {
    echo "stage-engine: OpenVINO runtime directory not found: $ov_runtime" >&2
    exit 1
  }

  case "$LIBEXT" in
  so)
    ov_lib_dirs=("$ov_runtime/lib/intel64" "$ov_runtime/lib" "$ov_runtime/3rdparty/tbb/lib")
    ov_patterns=("libopenvino*.so*" "libittnotify*.so*" "libtbb*.so*")
    ;;
  dylib)
    ov_lib_dirs=("$ov_runtime/lib/intel64" "$ov_runtime/lib" "$ov_runtime/3rdparty/tbb/lib")
    ov_patterns=("libopenvino*.dylib*" "libittnotify*.dylib*" "libtbb*.dylib*")
    ;;
  dll)
    ov_lib_dirs=("$ov_runtime/bin/intel64/Release" "$ov_runtime/bin" "$ov_runtime/lib")
    ov_patterns=("openvino*.dll" "tbb*.dll")
    ;;
  esac

  ov_staged=0
  for dir in "${ov_lib_dirs[@]}"; do
    [ -d "$dir" ] || continue
    for pattern in "${ov_patterns[@]}"; do
      for src in "$dir"/$pattern; do
        [ -e "$src" ] || [ -L "$src" ] || continue
        stage_lib "$src"
        ov_staged=$((ov_staged + 1))
      done
    done
  done
  [ "$ov_staged" -gt 0 ] || {
    echo "stage-engine: no OpenVINO runtime libraries found below $ov_runtime" >&2
    exit 1
  }
  echo "stage-engine: staged $ov_staged OpenVINO runtime libraries"
fi

# SYCL is also a dynamically loaded ggml backend.  The oneAPI compiler and
# Level Zero loader are not part of a normal desktop installation, so copy the
# redistributable oneAPI runtime libraries beside the worker for a portable
# package.  The Intel GPU driver/Level Zero implementation remains a host
# dependency, just as it does for OpenVINO.
sycl_module=""
for candidate in "$DEST"/libggml-sycl.* "$DEST"/ggml-sycl.dll; do
  if [ -e "$candidate" ] || [ -L "$candidate" ]; then
    sycl_module="$candidate"
    break
  fi
done

if [ -n "$sycl_module" ]; then
  oneapi_root="${ONEAPI_ROOT:-/opt/intel/oneapi}"
  [ -d "$oneapi_root" ] || {
    echo "stage-engine: ggml-sycl was built but oneAPI root is missing: $oneapi_root" >&2
    echo "stage-engine: set ONEAPI_ROOT to the oneAPI installation directory" >&2
    exit 1
  }

  # These are the runtime families used by the Intel SYCL backend.  Search
  # the installation rather than assuming a particular oneAPI component
  # version (e.g. compiler/latest versus compiler/2026.0).
  sycl_patterns=(
    "libsycl.*" "libpi_level_zero.*" "libur_loader.*"
    "libur_adapter_level_zero.*" "libdnnl.*" "libmkl_sycl_blas.*"
    "libmkl_intel_lp64.*" "libmkl_core.*" "libtbb.*"
    "libimf.*" "libsvml.*" "libintlc.*" "libirng.*"
  )
  sycl_staged=0
  for pattern in "${sycl_patterns[@]}"; do
    while IFS= read -r -d '' src; do
      stage_lib "$src"
      sycl_staged=$((sycl_staged + 1))
    done < <(find -L "$oneapi_root" -type f -name "$pattern" -print0 2>/dev/null)
  done
  [ "$sycl_staged" -gt 0 ] || {
    echo "stage-engine: no oneAPI SYCL runtime libraries found below $oneapi_root" >&2
    exit 1
  }
  echo "stage-engine: staged $sycl_staged oneAPI SYCL runtime libraries"
fi

[ -n "$cuda_module" ] || exit 0

# The module's own import names say which runtime it needs and with which
# major; they are plain strings in the binary (ELF .dynstr, PE import table),
# so no objdump/dumpbin is needed. cublasLt is reached through cublas, hence
# the closure over what has been staged.
if [ "$LIBEXT" = "dll" ]; then
  import_re='(cudart|cublas|cublasLt)64_[0-9]+\.dll'
else
  import_re='libcu(dart|blas|blasLt)\.so\.[0-9]+'
fi
imports_of() { tr -d '\0' < "$1" | grep -aoE "$import_re" | sort -u; }

needed="$(imports_of "$cuda_module")"
[ -n "$needed" ] || {
  echo "stage-engine: $(basename "$cuda_module") imports no CUDA runtime library" >&2
  exit 1
}

# Toolkit layouts differ (lib64, lib, targets/<arch>/lib; bin or bin/x64, with
# nvcc itself under bin/x64 on newer Windows toolkits), so the runtime is
# searched for by name under each candidate root rather than by fixed path.
first="$(echo "$needed" | head -1)"
nvcc="$(command -v nvcc 2>/dev/null || true)"
roots=("${CUDA_PATH:-}" "${CUDA_HOME:-}")
[ -n "$nvcc" ] && roots+=("$(dirname "$nvcc")/.." "$(dirname "$nvcc")/../..")
LIBDIR=""
for root in "${roots[@]}"; do
  [ -n "$root" ] && [ -d "$root" ] || continue
  hit="$(find -L "$root" -maxdepth 4 -iname "$first" -print -quit 2>/dev/null)"
  if [ -n "$hit" ]; then LIBDIR="$(dirname "$hit")"; break; fi
done
[ -n "$LIBDIR" ] || {
  echo "stage-engine: $(basename "$cuda_module") needs $first, found in no CUDA toolkit" >&2
  echo "stage-engine: CUDA_PATH='${CUDA_PATH:-}' CUDA_HOME='${CUDA_HOME:-}' nvcc='${nvcc}'" >&2
  exit 1
}

runtime=0
staged_names=""
queue="$needed"
while [ -n "$queue" ]; do
  next=""
  for name in $queue; do
    case " $staged_names " in *" $name "*) continue ;; esac
    matched=0
    for src in "$LIBDIR/$name"*; do
      [ -e "$src" ] || [ -L "$src" ] || continue
      stage_lib "$src"
      matched=$((matched + 1))
    done
    if [ "$matched" -eq 0 ]; then
      echo "stage-engine: $name is imported but missing from $LIBDIR" >&2
      exit 1
    fi
    runtime=$((runtime + matched))
    staged_names="$staged_names $name"
    next="$next $(imports_of "$DEST/$name")"
  done
  queue="$next"
done

echo "stage-engine: staged $runtime CUDA runtime libraries from $LIBDIR"
