/*
 * USB serial on a host that reaches it through the platform (Android's USB
 * host API, behind a method channel): the devices plugged in, the person's
 * permission, and a port. Linux needs none of this: the core opens a tty
 * itself (services/flash/serial/serial_linux_io.dart, termios over FFI).
 */
import '../services/flash/serial/serial_port.dart';

abstract interface class UsbSerialHost {
  Future<List<SerialDevice>> listDevices();
  Future<bool> requestPermission(String deviceId);

  /// Called when a device is plugged in or removed.
  set onDevicesChanged(void Function()? f);

  SerialPort open(String portId);
}
