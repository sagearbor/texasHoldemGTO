// Finds Google Cast devices on the Wi-Fi: mDNS (Bonjour) service
// _googlecast._tcp. Each device answers with a PTR (its instance), an SRV
// (host + port 8009), a TXT (fn = the name people gave it, md = model) and
// an A record (IPv4).
//
// Android: the Wi-Fi driver drops multicast unless an app holds a
// MulticastLock (native helper `multicastLock` on felt_notes/tv_cast), and
// SO_REUSEPORT is not available, so the socket is bound without it.
// iOS: raw multicast needs Apple's multicast entitlement, which this app
// does not have; the Cast option is Android-only for now.

import 'dart:async';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

const castService = '_googlecast._tcp.local';

class CastDevice {
  /// The device's mDNS instance name (unique on the network).
  final String id;

  /// The friendly name ("Living room TV"); falls back to the model.
  final String name;
  final String? model;
  final String host;
  final int port;

  const CastDevice({required this.id, required this.name, required this.host, this.port = 8009, this.model});

  @override
  String toString() => 'CastDevice($name @ $host:$port)';
}

/// TXT record lines (`fn=Den TV`, `md=Chromecast`, …) as a map.
Map<String, String> parseCastTxt(String text) {
  final out = <String, String>{};
  for (final line in text.split('\n')) {
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    out[line.substring(0, eq)] = line.substring(eq + 1);
  }
  return out;
}

/// The name to show: TXT `fn`, else the instance name without the service
/// suffix ("Chromecast-4f2c…"), else the model.
String castDeviceName(String instance, Map<String, String> txt) {
  final fn = txt['fn']?.trim();
  if (fn != null && fn.isNotEmpty) return fn;
  final i = instance.indexOf('._googlecast');
  final bare = i > 0 ? instance.substring(0, i) : instance;
  return bare.isNotEmpty ? bare : (txt['md'] ?? 'Cast device');
}

/// Something that streams Cast devices for [timeout], then closes.
typedef CastDiscovery = Stream<CastDevice> Function(Duration timeout);

/// The real discovery (multicast_dns). Each device is emitted once.
Stream<CastDevice> discoverCastDevices(Duration timeout) {
  final out = StreamController<CastDevice>();
  final seen = <String>{};
  MDnsClient? client;
  Future<void> run() async {
    client = MDnsClient(rawDatagramSocketFactory: _bind);
    await client!.start(interfacesFactory: _interfaces);
    final pending = <Future<void>>[];
    await for (final ptr
        in client!.lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(castService), timeout: timeout)) {
      final instance = ptr.domainName;
      if (!seen.add(instance)) continue;
      pending.add(_resolve(client!, instance).then((d) {
        if (d != null && !out.isClosed) out.add(d);
      }).catchError((Object _) {}));
    }
    await Future.wait(pending);
  }

  out.onListen = () {
    run().catchError((Object e) {
      if (!out.isClosed) out.addError(e);
    }).whenComplete(() {
      client?.stop();
      if (!out.isClosed) out.close();
    });
  };
  return out.stream;
}

Future<CastDevice?> _resolve(MDnsClient c, String instance) async {
  const t = Duration(seconds: 3);
  final srv = await _first(c.lookup<SrvResourceRecord>(ResourceRecordQuery.service(instance), timeout: t));
  if (srv == null) return null;
  final txtRec = await _first(c.lookup<TxtResourceRecord>(ResourceRecordQuery.text(instance), timeout: t));
  final ip = await _first(c.lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(srv.target), timeout: t));
  if (ip == null) return null;
  final txt = parseCastTxt(txtRec?.text ?? '');
  return CastDevice(
    id: instance,
    name: castDeviceName(instance, txt),
    model: txt['md'],
    host: ip.address.address,
    port: srv.port,
  );
}

Future<T?> _first<T>(Stream<T> s) async {
  await for (final x in s) {
    return x;
  }
  return null;
}

Future<RawDatagramSocket> _bind(dynamic host, int port,
        {bool reuseAddress = true, bool reusePort = false, int ttl = 1}) =>
    RawDatagramSocket.bind(host, port,
        reuseAddress: reuseAddress, reusePort: Platform.isAndroid ? false : reusePort, ttl: ttl);

/// Wi-Fi first: joining multicast on a cellular interface can fail, and
/// Cast devices are only ever on the LAN.
Future<Iterable<NetworkInterface>> _interfaces(InternetAddressType type) async {
  final all = await NetworkInterface.list(includeLinkLocal: false, type: type);
  final lan = all.where((i) => RegExp(r'^(wlan|eth|en|ap|swlan)').hasMatch(i.name)).toList();
  return lan.isNotEmpty ? lan : all;
}
