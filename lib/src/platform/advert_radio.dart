/*
 * The BLE5 advert radio, as the mesh uses it: the off-grid broadcast plane
 * (docs/ble5.md). The app backs it with Ble5Bus and BleService (platform
 * channels); a program with no Bluetooth (the server, a test) gets
 * [NoAdvertRadio], which airs nothing and hears nothing, so the mesh runs its
 * other bearers (LAN) and stays quiet on this one.
 */
import 'dart:typed_data';

import 'package:reticulum/reticulum.dart';

abstract interface class AdvertRadio {
  /// This controller's advert ceiling in bytes; 0 when there is no radio.
  int get maxPayload;

  /// Can this device advertise BLE5 frames at all, and is the adapter on?
  Future<bool> supported();
  Future<bool> adapterOn();

  /// Is the radio up right now (synchronous; the service's last reading).
  bool get poweredOn;

  /// Withdraw a keyed frame from the advertising set.
  Future<void> removeFrame(String key);

  /// Deliver received frames of [subtype] (see Ble5Subtype) to [handler].
  void onFrame(int subtype, void Function(Ble5Frame) handler);

  Future<void> startScan();

  /// Register/refresh a keyed frame on the shared advertising set; true when
  /// the radio ACCEPTED it (a frame over the ceiling is refused).
  /// [prio] puts it ahead of the rotation (a reply someone is waiting for).
  Future<bool> advertiseFrame(String key, int subtype, Uint8List data,
      {Duration ttl, bool prio});

  /// Queue [payload] for airing on behalf of [owner], routed by size (a small
  /// one is broadcast, a large one goes over a transient GATT link).
  void enqueueAdvert(Object owner, Uint8List payload,
      {required int subtype, Duration ttl});
}

class NoAdvertRadio implements AdvertRadio {
  const NoAdvertRadio();
  @override
  int get maxPayload => 0;
  @override
  Future<bool> supported() async => false;
  @override
  Future<bool> adapterOn() async => false;
  @override
  bool get poweredOn => false;
  @override
  Future<void> removeFrame(String key) async {}
  @override
  void onFrame(int subtype, void Function(Ble5Frame) handler) {}
  @override
  Future<void> startScan() async {}
  @override
  Future<bool> advertiseFrame(String key, int subtype, Uint8List data,
          {Duration ttl = const Duration(seconds: 35), bool prio = false}) async =>
      false;
  @override
  void enqueueAdvert(Object owner, Uint8List payload,
      {required int subtype, Duration ttl = const Duration(seconds: 10)}) {}
}
