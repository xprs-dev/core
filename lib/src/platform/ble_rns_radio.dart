/*
 * A Bluetooth radio Reticulum can run over, as RnsService drives it: the
 * reticulum package's RnsBleRadio plus starting it and letting a wanted path
 * request through. The app's are platform channels (BLE5 adverts, GATT); a
 * program with no Bluetooth has none, and CoreHost's factories return null.
 */
import 'dart:typed_data';

import 'package:reticulum/src/services/reticulum/rns_ble_interface.dart';

abstract interface class BleRnsRadio implements RnsBleRadio {
  /// Can this device run this radio at all.
  Future<bool> supported();

  Future<void> startScan();

  /// Let a path request for [destHash] through the radio's sweep, because
  /// somebody is waiting on it.
  void wantPathTo(Uint8List destHash);
}
