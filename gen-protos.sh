#!/bin/bash

# MQTT protos
compile-proto-file --proto proto/mqtt.proto --out gen

# Test protos
compile-proto-file --proto proto/test.proto --out gen
