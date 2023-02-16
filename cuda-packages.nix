{ lib,
  stdenv,
  runCommand,
  dpkg,
  makeWrapper,
  autoPatchelfHook,
  autoAddOpenGLRunpathHook,
  symlinkJoin,
  expat,
  ncurses5,
  pkg-config,
  substituteAll,
  l4t,

  debs,
  cudaVersion,
}:

let
  # We should use gcc10 to match CUDA 11.4, but we get link errors on opencv and torch2trt if we do
  # ../../lib/libopencv_core.so.4.5.4: undefined reference to `__aarch64_ldadd4_acq_rel
  gccForCuda = stdenv.cc;

  cudaVersionDashes = lib.replaceStrings [ "." ] [ "-"] cudaVersion;

  debsForSourcePackage = srcPackageName: lib.filter (pkg: (pkg.source or "") == srcPackageName) (builtins.attrValues debs.common);

  # TODO: Fix the pkg-config files
  buildFromDebs =
    { name, srcs, version ? debs.common.${name}.version,
      sourceRoot ? "source", buildInputs ? [], nativeBuildInputs ? [],
      postPatch ? "", postFixup ? "", autoPatchelf ? true, ...
    }@args:
    stdenv.mkDerivation ((lib.filterAttrs (n: v: !(builtins.elem n [ "name" "autoPatchelf" ])) args) // {
      pname = name;
      inherit version srcs;

      nativeBuildInputs = [ dpkg autoPatchelfHook autoAddOpenGLRunpathHook ] ++ nativeBuildInputs;
       buildInputs =
         (if stdenv.system == "aarch64-linux"
         then [ "${toString (stdenv.cc.cc.lib.lib + "/aarch64-unknown-linux-gnu")}" ]
         else []
         ) ++ buildInputs;

      unpackCmd = "for src in $srcs; do dpkg-deb -x $src source; done";

      dontConfigure = true;
      dontBuild = true;
      noDumpEnvVars = true;

      postPatch = ''
        if [[ -d usr ]]; then
          cp -r usr/. .
          rm -rf usr
        fi

        if [[ -d local ]]; then
          cp -r local/. .
          rm -rf local
        fi

        if [[ -d cuda-${cudaVersion} ]]; then
          [[ -L cuda-${cudaVersion}/include ]] && rm -r cuda-${cudaVersion}/include
          [[ -L cuda-${cudaVersion}/lib64 ]] && rm -r cuda-${cudaVersion}/lib64 && ln -s lib lib64
          cp -r cuda-${cudaVersion}/. .
          rm -rf cuda-${cudaVersion}
        fi

        if [[ -d targets ]]; then
          cp -r targets/*/* .
          rm -rf targets
        fi

        if [[ -d etc ]]; then
          rm -rf etc/ld.so.conf.d
          rmdir --ignore-fail-on-non-empty etc
        fi

        if [[ -d include/aarch64-linux-gnu ]]; then
          cp -r include/aarch64-linux-gnu/. include/
          rm -rf include/aarch64-linux-gnu
        fi

        if [[ -d lib/aarch64-linux-gnu ]]; then
          cp -r lib/aarch64-linux-gnu/. lib/
          rm -rf lib/aarch64-linux-gnu
        fi

        rm -f lib/ld.so.conf

        ${postPatch}
      '';

      installPhase = ''
        cp -r . $out
      '';

      passthru.meta = {
        license = with lib.licenses; [ unfree ];
      };
    });

  # Combine all the debs that originated from the same source package and build
  # from that
  buildFromSourcePackage = { name, ...}@args: buildFromDebs ({
    inherit name;
    # Just using the first package for the version seems fine
    version = (lib.head (debsForSourcePackage name)).version;
    srcs = builtins.map (deb: deb.src) (debsForSourcePackage name);
  } // args);

  cudaPackages = {
    cublas = buildFromSourcePackage { name = "cublas"; };
    cudnn = buildFromSourcePackage { name = "cudnn"; };
    cuda = buildFromSourcePackage { name = "cuda";
      buildInputs = [ expat ncurses5 ];
      preFixup = ''
        # Some build systems look for libcuda.so.1 expliticly:
        ln -s $out/lib/stubs/libcuda.so $out/lib/stubs/libcuda.so.1
      '';
    };

    # Combined package. We construct it from the debs, since nvidia doesn't
    # distribute a combined cudatoolkit package for jetson
    cudatoolkit = (symlinkJoin {
      name = "cudatoolkit";
      version = cudaVersion;
      paths = with cudaPackages; [
        cuda cudnn cublas
      ];
      # Bits from upstream nixpkgs cudatoolkit
      postBuild = ''
        # Ensure that cmake can find CUDA.
        mkdir -p $out/nix-support
        echo "cmakeFlags+=' -DCUDA_TOOLKIT_ROOT_DIR=$out'" >> $out/nix-support/setup-hook

        # Set the host compiler to be used by nvcc for CMake-based projects:
        # https://cmake.org/cmake/help/latest/module/FindCUDA.html#input-variables
        echo "cmakeFlags+=' -DCUDA_HOST_COMPILER=${gccForCuda}/bin'" >> $out/nix-support/setup-hook
      '';
    } // {
      cc = gccForCuda;
      majorMinorVersion = lib.versions.majorMinor cudaVersion;
      majorVersion = lib.versions.majorMinor cudaVersion;
    });

    ### Below are things that are not included in the cudatoolkit package

    # https://docs.nvidia.com/deploy/cuda-compatibility/index.html
    # TODO: This needs to be linked directly against driver libs
    # cuda-compat = buildFromSourcePackage { name = "cuda-compat"; };

    # Test with:
    # ./result/bin/trtexec --onnx=mnist.onnx
    # (mnist.onnx is from libnvinfer-samples deb)
    # TODO: This package is too large to want to just combine everything. Maybe split back into lib/dev/bin subpackages?
    tensorrt = let
      # Filter out samples. They're too big
      tensorrtDebs = builtins.filter (p: !(lib.hasInfix "libnvinfer-samples" p.filename)) (debsForSourcePackage "tensorrt");
    in buildFromDebs {
      name = "tensorrt";
      # Just using the first package for the version seems fine
      version = (lib.head tensorrtDebs).version;
      srcs = builtins.map (deb: deb.src) tensorrtDebs;

      buildInputs = (with cudaPackages; [ cuda_cudart libcublas cudnn ]) ++ (with l4t; [ l4t-core l4t-multimedia ]);
      # Remove unnecessary (and large) static libs
      postPatch = ''
        rm -rf lib/*.a

        mv src/tensorrt/bin bin
      '';

      # Tell autoPatchelf about runtime dependencies.
      # (postFixup phase is run before autoPatchelfHook.)
      postFixup = ''
        echo "Patching RPATH of libnvinfer libs"
        patchelf --debug --add-needed libnvinfer.so $out/lib/libnvinfer*.so.*
      '';
    };

    # vpi2
    vpi2 = buildFromDebs {
      name = "vpi2";
      version = debs.common.vpi2-dev.version;
      srcs = [ debs.common.libnvvpi2.src debs.common.vpi2-dev.src ];
      sourceRoot = "source/opt/nvidia/vpi2";
      buildInputs = (with l4t; [ l4t-core l4t-cuda l4t-nvsci l4t-3d-core l4t-multimedia l4t-pva ])
        ++ (with cudaPackages; [ libcufft ]);
      patches = [ ./vpi2.patch ];
      postPatch = ''
        rm -rf etc
        substituteInPlace lib/cmake/vpi/vpi-config.cmake --subst-var out
      '';
    };

    # Needed for vpi2-samples benchmark w/ pva to work
    vpi2-firmware = runCommand "vpi2-firmware" { nativeBuildInputs = [ dpkg ]; } ''
      dpkg-deb -x ${debs.common.libnvvpi2.src} source
      install -D -t $out/lib/firmware source/opt/nvidia/vpi2/lib64/priv/pva_auth_allowlist
    '';

    # TODO:
    #  libnvidia-container
    #  libcudla
  };
in cudaPackages
