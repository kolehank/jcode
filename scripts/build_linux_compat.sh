#!/usr/bin/env bash
set -euo pipefail

# Build a portable Linux release artifact (x86_64 or aarch64) against the
# CentOS 7 / manylinux2014 glibc 2.17 baseline so the resulting binary runs on
# older distributions, newer Debian/Ubuntu containers used by Terminal-Bench
# tasks, and Xinchuang (信创) machines that ship glibc 2.23/2.28. The ARM64
# build additionally rebuilds std from source with emulated TLS (Termux
# contract, same as the previous native-runner lane) while preserving the
# same glibc 2.17 baseline via the manylinux2014_aarch64 image.

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
out_dir="${1:-$repo_root/dist}"

if [[ "$#" -gt 1 ]]; then
  echo "Usage: $0 [out-dir]" >&2
  exit 1
fi

if [[ "$out_dir" != /* ]]; then
  out_dir="$repo_root/$out_dir"
fi

artifact="${JCODE_COMPAT_ARTIFACT:-jcode-linux-x86_64}"
profile="${JCODE_COMPAT_PROFILE:-release}"
target="${JCODE_COMPAT_TARGET:-x86_64-unknown-linux-gnu}"
case "$target" in
  x86_64-unknown-linux-gnu) default_image="quay.io/pypa/manylinux2014_x86_64" ;;
  aarch64-unknown-linux-gnu) default_image="quay.io/pypa/manylinux2014_aarch64" ;;
  *)
    echo "Unsupported compatibility target: $target (expected x86_64- or aarch64-unknown-linux-gnu)" >&2
    exit 1
    ;;
esac
image="${JCODE_COMPAT_IMAGE:-$default_image}"
cache_root="${JCODE_COMPAT_CACHE_DIR:-$HOME/.cache/jcode-linux-compat}"

mkdir -p "$out_dir" \
  "$cache_root/cargo-registry" \
  "$cache_root/cargo-git" \
  "$cache_root/rustup"

host_uid="$(id -u)"
host_gid="$(id -g)"

# Compute git build metadata on the HOST and hand it to the container via a
# metadata file (read by jcode-build-meta/build.rs through
# JCODE_BUILD_METADATA_FILE). The repo is bind-mounted into the container and
# owned by the host UID while git inside the container runs as root, so any
# in-container `git` call trips git's "dubious ownership" guard
# (CVE-2022-24765) and fails. That previously zeroed out the embedded git hash,
# date, AND changelog, shipping release binaries that report
# "vX.Y.Z (unknown) (unknown)" with an empty /changelog overlay. Computing the
# values here makes the embedded metadata independent of container-git. This
# mirrors scripts/remote_build.sh.
git_hash=""
git_date=""
git_tag=""
git_dirty="0"
changelog_raw=""
if command -v git >/dev/null 2>&1 && git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
  git_hash="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || true)"
  git_date="$(git -C "$repo_root" log -1 --format=%ci 2>/dev/null || true)"
  git_tag="$(git -C "$repo_root" describe --tags --always 2>/dev/null || true)"
  changelog_raw="$(git -C "$repo_root" log -700 --format='%h|%ct|%D|%s' 2>/dev/null || true)"
  if [[ -n "$(git -C "$repo_root" status --porcelain 2>/dev/null || true)" ]]; then
    git_dirty="1"
  fi
else
  echo "warning: git metadata unavailable on host; embedded changelog/version may be empty" >&2
fi

metadata_file="$(mktemp)"
trap 'rm -f "$metadata_file"' EXIT
{
  printf 'git_hash=%s\n' "$git_hash"
  printf 'git_date=%s\n' "$git_date"
  printf 'git_tag=%s\n' "$git_tag"
  printf 'git_dirty=%s\n' "$git_dirty"
  printf 'changelog_raw<<JCODE_CHANGELOG_EOF\n%s\nJCODE_CHANGELOG_EOF\n' "$changelog_raw"
} > "$metadata_file"

echo "Building portable Linux release in Docker image: $image"
echo "Output dir: $out_dir"
echo "Embedding git metadata: hash=${git_hash:-<none>} tag=${git_tag:-<none>} dirty=$git_dirty changelog_lines=$(printf '%s' "$changelog_raw" | grep -c '' || true)"

docker run --rm \
  -e CARGO_TERM_COLOR=always \
  -e CARGO_PROFILE_RELEASE_OPT_LEVEL \
  -e CARGO_BUILD_JOBS \
  -e JCODE_CI_BUILD \
  -e JCODE_RELEASE_BUILD="${JCODE_RELEASE_BUILD:-1}" \
  -e JCODE_BUILD_SEMVER="${JCODE_BUILD_SEMVER:-}" \
  -e JCODE_BUILD_METADATA_FILE=/jcode-build-meta \
  -e JCODE_BUILD_GIT_HASH="$git_hash" \
  -e JCODE_BUILD_GIT_DATE="$git_date" \
  -e JCODE_BUILD_GIT_TAG="$git_tag" \
  -e JCODE_BUILD_GIT_DIRTY="$git_dirty" \
  -e JCODE_COMPAT_PROFILE="$profile" \
  -e JCODE_COMPAT_TARGET="$target" \
  -e HOST_UID="$host_uid" \
  -e HOST_GID="$host_gid" \
  -v "$repo_root:/work" \
  -v "$metadata_file:/jcode-build-meta:ro" \
  -v "$out_dir:/out" \
  -v "$cache_root/cargo-registry:/root/.cargo/registry" \
  -v "$cache_root/cargo-git:/root/.cargo/git" \
  -v "$cache_root/rustup:/root/.rustup" \
  -w /work \
  "$image" \
  bash -lc '
    set -euo pipefail
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq \
        build-essential \
        ca-certificates \
        curl \
        git \
        libssl-dev \
        perl \
        pkg-config
    elif command -v yum >/dev/null 2>&1; then
      yum install -y \
        ca-certificates \
        curl \
        gcc \
        gcc-c++ \
        git \
        make \
        openssl-devel \
        perl-core \
        pkgconfig \
        tar \
        gzip
      update-ca-trust || true
    else
      echo "Unsupported build image: expected apt-get or yum" >&2
      exit 1
    fi

    # The OpenSSL 3 Configure script imports core modules that minimal
    # manylinux2014 images split into separate RPMs. Installing perl-core keeps
    # the build from failing one missing module at a time as OpenSSL evolves.
    perl -MIPC::Cmd -MTime::Piece -e 1

    if [[ ! -x /root/.cargo/bin/cargo ]]; then
      curl https://sh.rustup.rs -sSf | sh -s -- -y --profile minimal --default-toolchain stable
    fi
	    source /root/.cargo/env

	    # ARM64 preserves the emulated-TLS Termux contract, which needs the
	    # nightly compiler plus rust-src to rebuild std for the target
	    # (-Z build-std). The official aarch64-unknown-linux-gnu toolchain
	    # keeps the glibc 2.17 baseline of this container, so the linked
	    # artifact stays portable. Must run after `source /root/.cargo/env`
	    # so rustup is on PATH.
	    if [[ "$JCODE_COMPAT_TARGET" == aarch64-unknown-linux-gnu ]]; then
	      rustup toolchain install nightly --profile minimal --component rust-src
	    fi

	    # Belt-and-suspenders: the host-computed metadata file
	    # (JCODE_BUILD_METADATA_FILE=/jcode-build-meta) is the primary source of
	    # git hash/date/changelog, but mark the bind-mounted repo as a safe
	    # directory so any in-container git fallback still works despite the
	    # host-UID/root-git ownership mismatch (CVE-2022-24765 guard).
	    git config --global --add safe.directory /work 2>/dev/null || true

	    export CARGO_TARGET_DIR=/work/target/linux-compat
	    mkdir -p "$CARGO_TARGET_DIR"
	    export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-1}"
	    export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS="${CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS:--C link-arg=-static-libgcc}"
	    build_command=(cargo build)
	    build_args=(--locked --profile "$JCODE_COMPAT_PROFILE" --target "$JCODE_COMPAT_TARGET" \
	      -p jcode --bin jcode --features linux-compat-vendored-openssl)
	    if [[ "$JCODE_COMPAT_TARGET" == aarch64-unknown-linux-gnu ]]; then
	      # Same target-only emulated-TLS flags the native ARM64 release lane
	      # uses. Express them as a cargo --config file, the exact equivalent
	      # of [target.aarch64-unknown-linux-gnu] rustflags in .cargo/config
	      # (the mechanism the native runner lane relies on), plus the
	      # per-target env for good measure. The config file rides the
	      # explicit cargo argument list so no wrapper/transport can drop it,
	      # and -Z build-std rebuilds std with it (Termux contract). The env
	      # form alone was lost when the CI build went through justrust
	      # --local, which is why this lane uses plain cargo below.
	      export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS="${CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS:--C link-arg=-static-libgcc -Ztls-model=emulated}"
	      export RUSTUP_TOOLCHAIN=nightly
	      arm64_compat_config="$CARGO_TARGET_DIR/jcode-arm64-compat.toml"
	      cat > "$arm64_compat_config" <<'JCODE_COMPAT_CONFIG_EOF'
[target.aarch64-unknown-linux-gnu]
rustflags = ["-C", "link-arg=-static-libgcc", "-Z", "tls-model=emulated"]
JCODE_COMPAT_CONFIG_EOF
	      build_args+=( --config "$arm64_compat_config" -Zbuild-std=std,panic_abort )
	      # Also append the target flags to the workspace cargo config: the
	      # exact mechanism the native ARM64 runner lane uses, so every
	      # transport layer carries the emulated-TLS contract. The checkout
	      # is ephemeral in CI; the Cargo.lock guard is unaffected.
	      printf '\n[target.aarch64-unknown-linux-gnu]\nrustflags = ["-C", "link-arg=-static-libgcc", "-Z", "tls-model=emulated"]\n' >> /work/.cargo/config.toml
	    fi
	    if [[ "${JCODE_CI_BUILD:-0}" == 1 && "$JCODE_COMPAT_TARGET" != aarch64-unknown-linux-gnu ]]; then
	      # Hosted Ubuntu cannot produce our glibc 2.17 baseline yet. Run the
	      # static justrust client inside the existing manylinux2014 container.
	      # The ARM64 lane deliberately uses plain cargo instead: the
	      # container runs natively on ARM64 and cargo must receive the
	      # emulated-TLS config file unmodified.
	      export JUSTRUST_TOOLCHAIN=system JUSTRUST_SLOTS=0 JUSTRUST_NO_TELEMETRY=1
	      export JUSTRUST_INSTALL_DIR=/root/.local/bin
	      bash scripts/install_justrust_ci.sh
	      export PATH="$JUSTRUST_INSTALL_DIR:$PATH"
	      build_command=(justrust build --local)
	    fi
	    "${build_command[@]}" "${build_args[@]}"

        # Exercise the exact portable binary before packaging. Cloud upgrades
        # must not publish an artifact that cannot complete the handoff protocol.
        built="$CARGO_TARGET_DIR/$JCODE_COMPAT_TARGET/$JCODE_COMPAT_PROFILE/jcode"
        "$built" --no-update --no-selfdev --version
        for command in receive credentials router-credentials cancel-return; do
          "$built" --no-update --no-selfdev cloud "$command" --help >/dev/null
        done
        # Running inside the baseline image also checks dynamic dependencies;
        # check symbol versions explicitly so a newer accidental sysroot fails.
        newest_glibc=$(objdump -T "$built" | sed -n "s/.*GLIBC_\([0-9][0-9.]*\).*/\1/p" | sort -Vu | tail -n1)
        if [[ -z "$newest_glibc" || "$(printf "%s\n" 2.17 "$newest_glibc" | sort -V | tail -n1)" != 2.17 ]]; then
          echo "error: portable binary exceeds the glibc 2.17 baseline: $newest_glibc" >&2
          exit 1
        fi
        # ARM64 must keep the emulated-TLS contract that native Linux ARM64
        # kernels without TLS Variant 2 (Termux/Android) rely on. Mirror the
        # preview-hosted validation: readelf -sW covers both .symtab and
        # .dynsym, which matters because this container links libgcc
        # statically (-static-libgcc), so __emutls_get_address is a fully
        # defined local symbol rather than a dynamic UNDEF from libgcc_s.
        # objdump -T would miss it, which previously failed a correct build.
        if [[ "$JCODE_COMPAT_TARGET" == aarch64-unknown-linux-gnu ]]; then
          emutls_get=$(readelf -sW "$built" 2>/dev/null | grep -c "__emutls_get_address" || true)
          emutls_v=$(readelf -sW "$built" 2>/dev/null | grep -c "__emutls_v\." || true)
          pt_tls=$(readelf -lW "$built" 2>/dev/null | grep -c "TLS" || true)
          dyn_emutls=$(objdump -T "$built" 2>/dev/null | grep -c "__emutls" || true)
          echo "ARM64 emulated-TLS diagnostics: readelf-sW(__emutls_get_address)=$emutls_get readelf-sW(__emutls_v.)=$emutls_v PT_TLS=$pt_tls dynsym(__emutls)=$dyn_emutls"
          if [[ "$emutls_get" == "0" || "$emutls_v" == "0" || "$pt_tls" != "0" ]]; then
            echo "error: ARM64 binary does not satisfy the emulated-TLS contract" >&2
            exit 1
          fi
        fi

	    cp "$CARGO_TARGET_DIR/$JCODE_COMPAT_TARGET/$JCODE_COMPAT_PROFILE/jcode" "/out/'"$artifact"'.bin"
	    chmod +x "/out/'"$artifact"'.bin"
	    cat > "/out/'"$artifact"'" <<WRAPPER
#!/usr/bin/env sh
set -eu
self_path=\$0
if command -v readlink >/dev/null 2>&1; then
  resolved=\$(readlink -f -- "\$0" 2>/dev/null || true)
  if [ -n "\$resolved" ]; then
    self_path=\$resolved
  fi
fi
case "\$self_path" in
  */*) self_dir=\$(CDPATH= cd -- "\$(dirname -- "\$self_path")" && pwd) ;;
  *) self_dir=\$(pwd) ;;
esac
if [ -n "\${LD_LIBRARY_PATH:-}" ]; then
  export LD_LIBRARY_PATH="\$self_dir:\$LD_LIBRARY_PATH"
else
  export LD_LIBRARY_PATH="\$self_dir"
fi
exec "\$self_dir/'"$artifact"'.bin" "\$@"
WRAPPER
	    chmod +x "/out/'"$artifact"'"

	    # Preserve the OpenSSL runtime libraries used by the build image. Some
	    # Terminal-Bench containers are older than the build host and either lack
	    # libssl entirely or expose a different SONAME. The Harbor adapter uploads
	    # these sibling libraries and sets LD_LIBRARY_PATH for the jcode process.
	    ldd "/out/'"$artifact"'.bin" \
	      | awk "/lib(ssl|crypto)[.]so/ { print \$3 }" \
	      | while read -r lib; do
	          if [[ -n "$lib" && -f "$lib" ]]; then
	            cp -L "$lib" /out/
	          fi
	        done

		    extra_libs=()
		    for pattern in libssl.so\* libcrypto.so\*; do
		      for lib in $pattern; do
		        [[ -e "$lib" ]] && extra_libs+=("$lib")
		      done
		    done

		    if (( ${#extra_libs[@]} > 0 )); then
		      (cd /out && tar czf '"$artifact"'.tar.gz '"$artifact"' '"$artifact"'.bin "${extra_libs[@]}")
		    else
		      (cd /out && tar czf '"$artifact"'.tar.gz '"$artifact"' '"$artifact"'.bin)
		    fi

		    chown_inputs=("/out/'"$artifact"'" "/out/'"$artifact"'.bin" "/out/'"$artifact"'.tar.gz")
		    if (( ${#extra_libs[@]} > 0 )); then
		      for lib in "${extra_libs[@]}"; do
		        chown_inputs+=("/out/$lib")
		      done
		    fi
		    chown "$HOST_UID:$HOST_GID" "${chown_inputs[@]}" 2>/dev/null || true
		  '

# The docker invocation above is the last command in the script, so without an
# explicit check a failed build still exits 0: the in-container `bash -lc` can
# fail (daemon down, compile error) while this script reports success and leaves
# a stale or empty out_dir behind. Benchmark launchers pin artifact SHA-256s and
# would happily bank a previous build's binary, so verify the outputs exist
# before claiming success.
for required in "$out_dir/$artifact" "$out_dir/$artifact.bin" "$out_dir/$artifact.tar.gz"; do
  if [[ ! -s "$required" ]]; then
    echo "error: build did not produce $required" >&2
    exit 1
  fi
done

echo "Built artifacts:"
ls -lh "$out_dir/$artifact" "$out_dir/$artifact.tar.gz"

# Fail closed when the embedded hash does not match the tree that was built.
# `jcode-build-meta`'s build script deliberately does not watch .git/HEAD, so a
# cached build dir can silently embed a previous commit's hash (observed: an
# artifact built at 268913473 reporting c9ccb4f01). Provenance that is wrong is
# worse than provenance that is missing.
if [[ -n "$git_hash" ]]; then
  # `version` prints e.g. "version\tv0.61.2 (268913473)", so take the whole
  # value rather than just the first whitespace-separated field.
  embedded="$("$out_dir/$artifact.bin" --no-update --no-selfdev version 2>/dev/null \
    | awk -F'\t' '$1 == "version" { print $2 }')"
  if [[ -n "$embedded" && "$embedded" != *"$git_hash"* ]]; then
    echo "error: embedded build metadata reports '$embedded' but the tree is at '$git_hash'" >&2
    echo "       (stale build cache; re-run after 'cargo clean' or bump JCODE_BUILD_GIT_HASH)" >&2
    exit 1
  fi
fi
