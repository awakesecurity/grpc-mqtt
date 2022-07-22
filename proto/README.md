
An example of how the protobuf options `grpc-mqtt` supports can be used to change how splices are generated in template haskell functions such as `makeMQTTClientFuncs` or `mqttRemoteClientMethodMap`:

```protobuf
syntax = "proto3";

import "haskell/grpc/mqtt.proto";

package test;

// Enables batched streaming by default for all RPCs in the file.
option (haskell.grpc.mqtt.batched_stream_file) = true;

message HelloRequest { }

message TwoDigits {
  int32 fst_digit = 1;
  int32 snd_digit = 2;
}

message Response {
  string value = 1;
}

service ExampleService {
  // Enables zstandard compression with a compression level 10 for all RPCs in 
  // this service.
  option (haskell.grpc.mqtt.server_clevel_service) = CLEVEL_10;
  
  rpc SayHello(HelloRequest) returns (stream Response);

  rpc AddTwoDigits(TwoDigits) returns (stream Response) { 
    // Overrides the file's default batched_stream value and disables batching 
    // for this method's response stream.
    option (haskell.grpc.mqtt.batched_stream) = true;
  }; 

  rpc SayGoodbye(HelloRequest) returns (stream Response) {
    // Overrides the service's default compression level value and disables 
    // response compression for this method.
    option (haskell.grpc.mqtt.server_clevel) = CLEVEL_DISABLE;
  };
}
```