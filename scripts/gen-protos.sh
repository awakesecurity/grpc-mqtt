#!/bin/bash

log_debug_file="$(basename $0)"

echo_fmt_debug () {
  echo "${log_debug_file}: $1"
}

echo_fmt_error () {
  echo "${log_debug_file}: $(tput setaf 1)error:$(tput sgr0) $1"
}

# Generate grpc-mqtt *.hs source files from *.proto files.
# * @arg $1: The include directory for compile-proto-file to use.
# * @arg $2: The directory containing *.proto files to compile.
# * @arg $3: An output directory for compile-proto-file to use.
compile_proto_files () {
  local inc_dir=$1
  local src_dir=$2
  local out_dir=$3

  if [ -d $src_dir ]; then
    local proto_files=$(find $src_dir -name '*.proto')

    if [ proto_files ]; then
      echo_fmt_debug "compiling *.proto files in ($src_dir) to ($out_dir)."

      for proto in ${proto_files}; do
        local proto_file="${proto#$inc_dir/}"

        echo_fmt_debug ".. compiling ($proto) to ($proto_file)"
        $(compile-proto-file --includeDir $inc_dir --out $out_dir --proto $proto_file)
      done
    else
      echo_fmt_error "no *.proto files in ($src_dir)."
    fi
  else
    echo_fmt_error "*.proto directory ($src_dir) does not exist."
  fi
}

if [ $(command -v compile-proto-file) ]; then
  # Generate grpc-mqtt *.hs source files from *.proto files.
  # compile_proto_files "." "proto" "gen/src"

  # Generate test-suite *.hs source files from mock *.proto files.
  compile_proto_files "./test" "./test" "gen/test"
else
  # maybe you forgot to enter nix-shell?
  echo_fmt_debug "could not find 'compile-proto-file' from proto3-suite."
fi
