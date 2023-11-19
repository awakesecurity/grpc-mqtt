{ }:

final: prev: {
  grpc = final.callPackage (import ../packages/grpc.nix) {
    # grpc builds with c++14 so abseil must also be built that way
    abseil-cpp = final.abseil-cpp_202111.override {
      cxxStandard = "14";
    };
  };
}
