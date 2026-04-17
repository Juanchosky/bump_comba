import 'dart:async';
import 'package:cast/cast.dart';
import 'package:flutter/foundation.dart';
import 'package:bonsoir/bonsoir.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:http/http.dart' as http;

class CastService extends ChangeNotifier {
  static final CastService _instance = CastService._internal();
  factory CastService() => _instance;
  CastService._internal();

  List<CastDevice> _devices = [];
  List<CastDevice> get devices => _devices;

  CastDevice? _connectedDevice;
  CastDevice? get connectedDevice => _connectedDevice;

  CastSession? _session;
  CastSession? get session => _session;

  String? _realSessionId;
  String? _transportId;

  bool _isScanning = false;
  bool get isScanning => _isScanning;

  final _deviceController = StreamController<List<CastDevice>>.broadcast();
  Stream<List<CastDevice>> get deviceStream => _deviceController.stream;

  BonsoirDiscovery? _discovery;

  Future<void> startDiscovery() async {
    if (_isScanning) return;
    _isScanning = true;
    _devices = [];
    notifyListeners();

    try {
      _discovery = BonsoirDiscovery(type: '_googlecast._tcp');
      await _discovery!.ready;
      await _discovery!.start();

      _discovery!.eventStream!.listen((event) {
        debugPrint('CastService: Event ${event.type}');

        if (event.type == BonsoirDiscoveryEventType.discoveryServiceFound) {
          if (event.service != null && _discovery != null) {
            debugPrint('CastService: Service Found ${event.service!.name}');
            event.service!.resolve(_discovery!.serviceResolver);
          }
        }

        if (event.type == BonsoirDiscoveryEventType.discoveryServiceResolved) {
          final service = event.service;
          if (service is ResolvedBonsoirService) {
            debugPrint(
              'CastService: Service resolved ${service.name} at ${service.host}:${service.port}',
            );
            _addDevice(service);
          }
        }
      });
    } catch (e) {
      debugPrint('CastService: discovery error: $e');
      _isScanning = false;
      notifyListeners();
    }
  }

  void _addDevice(ResolvedBonsoirService service) {
    final host = service.host;
    final port = service.port;
    final name = service.name;

    String friendlyName = name;
    if (service.attributes.containsKey('fn')) {
      friendlyName = service.attributes['fn']!;
    }

    if (host == null) return;

    final existingIndex = _devices.indexWhere(
      (d) => d.host == host && d.port == port,
    );
    if (existingIndex == -1) {
      final device = CastDevice(
        serviceName: name,
        name: friendlyName,
        host: host,
        port: port,
      );
      _devices.add(device);
      _deviceController.add(_devices);
      notifyListeners();
    }
  }

  Future<void> stopDiscovery() async {
    _isScanning = false;
    try {
      await _discovery?.stop();
    } catch (e) {
      debugPrint('CastService: Error stopping discovery: $e');
    }
    _discovery = null;
    notifyListeners();
  }

  Future<void> connect(CastDevice device) async {
    // Stop discovery before connecting to save resources and avoid socket conflicts/crashes
    await stopDiscovery();

    try {
      final session = await CastSessionManager().startSession(device);

      _session = session;
      _connectedDevice = device;

      // Reset internal IDs
      _realSessionId = null;
      _transportId = null;

      notifyListeners();

      session.stateStream.listen(
        (state) {
          if (state == CastSessionState.closed) {
            disconnect();
          }
        },
        onError: (e) {
          debugPrint('CastService: State stream error: $e');
          disconnect();
        },
      );

      // Listen for messages to get the real Session ID and Transport ID
      session.messageStream.listen(
        (message) {
          debugPrint('CastService: Incoming message: $message');

          if (message['type'] == 'RECEIVER_STATUS') {
            final status = message['status'];
            if (status != null &&
                status['applications'] != null &&
                (status['applications'] as List).isNotEmpty) {
              final app = status['applications'][0];
              _realSessionId = app['sessionId'];
              _transportId = app['transportId'];
              debugPrint(
                'CastService: Updated IDs - Session: $_realSessionId, Transport: $_transportId',
              );

              // Set volume to max when app is launched
              setVolume(1.0);
            }
          }
        },
        onError: (e) {
          debugPrint('CastService: Message stream error: $e');
          disconnect();
        },
      );

      // Important: Launch the Default Media Receiver app ID: CC1AD845
      const receiverNamespace = 'urn:x-cast:com.google.cast.receiver';

      debugPrint(
        'CastService: Requesting discovery status and launching Default Media Receiver...',
      );

      // First, get status to see what's currently running
      session.sendMessage(receiverNamespace, {
        'type': 'GET_STATUS',
        'requestId': _getRequestId(),
      });

      // Launch the Default Media Receiver
      session.sendMessage(receiverNamespace, {
        'type': 'LAUNCH',
        'appId': 'CC1AD845', // Default Media Receiver
        'requestId': _getRequestId(),
      });

      debugPrint('CastService: Connected to ${device.name}');

      // Enable Wakelock to keep CPU/Network alive when screen is off
      WakelockPlus.enable();
    } catch (e) {
      debugPrint('CastService: Error connecting: $e');
      disconnect();
      rethrow;
    }
  }

  Future<void> disconnect() async {
    if (_session != null) {
      try {
        await _session!.close();
      } catch (e) {
        debugPrint('CastService: Error closing session: $e');
      }
    }
    _session = null;
    _connectedDevice = null;
    _realSessionId = null;
    _transportId = null;

    // Disable Wakelock to save battery
    WakelockPlus.disable();

    notifyListeners();
    debugPrint('CastService: Disconnected');
  }

  Future<void> loadMedia(
    String url, {
    String? title,
    String? subtitle,
    String? mimeType,
    bool autoPlay = true,
  }) async {
    if (_session == null) {
      debugPrint('CastService: Cannot load media, no active session');
      return;
    }

    try {
      debugPrint('CastService: Preparing to load media: $url');

      // Resolve proper mime type to ensure correct player is used (e.g. HLS vs MP4)
      String finalMimeType = mimeType ?? _guessMimeType(url);
      if (mimeType == null) {
        // If not explicitly provided, try to sniff it from the network
        finalMimeType = await _resolveRealMimeType(url, finalMimeType);
      }

      debugPrint('CastService: Resolved MimeType: $finalMimeType for $url');

      final finalSessionId = _realSessionId ?? _session!.sessionId;

      debugPrint('CastService: Using Session ID: $finalSessionId');

      const connectionNamespace = 'urn:x-cast:com.google.cast.tp.connection';
      const mediaNamespace = 'urn:x-cast:com.google.cast.media';

      _session!.sendMessage(connectionNamespace, {'type': 'CONNECT'});

      final payload = {
        'type': 'LOAD',
        'requestId': _getRequestId(),
        'sessionId': finalSessionId,
        'media': {
          'contentId': url,
          'streamType': 'BUFFERED',
          'contentType': finalMimeType,
          'metadata': {
            'type': 1, // Generic Media Metadata
            'metadataType': 1,
            'title': title ?? 'Sin título',
            'subtitle': subtitle ?? '',
            'images': [
              // We could add an image here if passed
            ],
          },
        },
        'autoplay': autoPlay,
        'currentTime': 0,
      };

      debugPrint('CastService: Sending LOAD request: $payload');
      _session!.sendMessage(mediaNamespace, payload);
    } catch (e) {
      debugPrint('CastService: Error loading media: $e');
    }
  }

  Future<void> setVolume(double level) async {
    if (_session == null) return;
    try {
      const receiverNamespace = 'urn:x-cast:com.google.cast.receiver';
      _session!.sendMessage(receiverNamespace, {
        'type': 'SET_VOLUME',
        'volume': {'level': level.clamp(0.0, 1.0)},
        'requestId': _getRequestId(),
      });
      debugPrint('CastService: Volume set to $level');
    } catch (e) {
      debugPrint('CastService: Error setting volume: $e');
    }
  }

  Future<String> _resolveRealMimeType(String url, String defaultType) async {
    try {
      final uri = Uri.tryParse(url);
      if (uri == null) return defaultType;

      // Quick check for obvious HLS without network call
      if (url.contains('.m3u8')) return 'application/x-mpegurl';

      debugPrint('CastService: resolving content type for $url...');
      final response = await http.head(uri).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final contentType = response.headers['content-type'];
        if (contentType != null && contentType.isNotEmpty) {
          debugPrint('CastService: Server returned content-type: $contentType');
          // Map common variants
          if (contentType.contains('mpegurl') || contentType.contains('hls')) {
            return 'application/x-mpegurl';
          }
          if (contentType.contains('video/')) {
            return contentType; // Return the exact type from server
          }
        }
      }
    } catch (e) {
      debugPrint('CastService: Error resolving mime type: $e');
    }
    return defaultType;
  }

  String _guessMimeType(String url) {
    final lowerUrl = url.toLowerCase();
    if (lowerUrl.contains('.m3u8')) return 'application/x-mpegurl';
    if (lowerUrl.endsWith('.mp4')) return 'video/mp4';
    if (lowerUrl.endsWith('.mkv')) {
      return 'video/webm'; // Chrome prefers WebM/MP4, MKV container often works better as webm
    }
    if (lowerUrl.endsWith('.webm')) return 'video/webm';
    if (lowerUrl.endsWith('.mp3')) return 'audio/mpeg';
    if (lowerUrl.endsWith('.aac')) return 'audio/aac';
    return 'video/mp4'; // Default fallback
  }

  int _requestId = 1;
  int _getRequestId() => _requestId++;
}
