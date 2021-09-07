# grpc-mqtt

**Motivation**

This library enables the use of gRPC over an MQTT connection. This can be particularly useful when you have a distributed fleet of gRPC servers behind firewalls, as the servers can be accessible over MQTT without needing to accept incoming connections.

**Highlights**

- Makes gRPC calls over MQTT!
- Client and RemoteClient code can be generated from `.proto` files
- MQTT sessions can properly handle out-of-order messages
- MQTT sessions will avoid re-processing duplicate requests

**Overview**

This library attempts to closely mirror the API of `gRPC-haskell` so that it can be easily swapped in and out with existing gRPC infrastructure.
The basic flow of a request through this system:
![image](https://user-images.githubusercontent.com/7852262/124140617-a0844e00-da56-11eb-9a09-a4c4794c890e.png)


The two main components of this library are the modules `Client` and the `RemoteClient`.

**Client**

A connection to the MQTT broker can be created and used via `withMQTTGRPCClient` by providing an `MQTTConfig`.

Client functions for calling gRPC services over MQTT can be generated from your existing proto files with Template Haskell using `mqttClientFuncs`. The generated code requires the corresponding proto file to have also already been compiled using `proto3-suite`. See Test/ProtoClients.hs for an example.

General usage: 
```
withMQTTGRPCClient myMQTTConfig $ \client -> do
  let AddHello mqttAdd mqttHelloSS = addHelloMqttClient client baseTopic
  result <- mqttAdd (MQTTNormalRequest (TwoInts 4 6) 2 [])
  ...
```
Here `AddHello` is a type that was generated by `proto3-suite`, and `addHelloMqttClient` is generated with `mqttClientFuncs`

**RemoteClient**

The RemoteClient performs the actual gRPC requests on behalf of the Client. Similarily to the Client, the RemoteClient code can be generated using `mqttRemoteClientMethodMap`. See Test/ProtoRemoteClients.hs for an example. The resulting `MethodMap` is a mapping from gRPC method names to a function for making that request. These maps can be combined if you have multiple gRPC servers running on the machine.

General usage:
```
withGRPCClient myGRPCClientConfig $ \grpcClient -> do
  methodMap <- addHelloRemoteClientMethodMap grpcClient
  runRemoteClient myMQTTConfig baseTopic methodMap
```
Using multiple servers:
```
methodMapAH <- addHelloRemoteClientMethodMap grpcClient1
methodMapMG <- multGoodbyeRemoteClientMethodMap grpcClient2
let methodMap = methodMapAH <> methodMapMG
runRemoteClient myMQTTConfig baseTopic methodMap
```
