import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'api_service.dart';
import 'ws_service.dart';

enum CallState { idle, calling, incoming, connected }

class CallService {
  static CallService? _instance;
  static CallService get instance => _instance ??= CallService._();
  CallService._();

  CallState state = CallState.idle;
  String? peerLogin;
  String? callId;
  bool isVideo = false;
  bool isMuted = false;
  bool videoEnabled = false;
  bool remoteVideoActive = false;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  RTCVideoRenderer? localRenderer;
  RTCVideoRenderer? remoteRenderer;

  final List<RTCIceCandidate> _pendingCandidates = [];
  DateTime? _callStartedAt;

  final _stateController = StreamController<CallState>.broadcast();
  final _remoteStreamController = StreamController<MediaStream>.broadcast();

  Stream<CallState> get stateStream => _stateController.stream;
  Stream<MediaStream> get remoteStreamStream => _remoteStreamController.stream;

  Map<String, dynamic>? _pendingOffer;

  String _genCallId() {
    final rng = Random();
    return 'call-${DateTime.now().millisecondsSinceEpoch}-'
        '${rng.nextInt(999999).toString().padLeft(6, '0')}';
  }

  Future<Map<String, dynamic>> _fetchTurnCredentials() async {
    final resp = await http.get(
      Uri.parse('https://oshino.space/turn-credentials'),
      headers: ApiService.authHeaders,
    );
    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body);
      return data;
    }
    throw Exception('Не удалось получить TURN credentials');
  }

  Future<RTCPeerConnection> _createPeerConnection() async {
    final creds = await _fetchTurnCredentials();
    final urls = List<String>.from(creds['urls'] ?? []);

    final iceServers = [
      {'urls': urls.where((u) => u.startsWith('stun:')).toList()},
      {
        'urls': urls.where((u) => u.startsWith('turn:')).toList(),
        'username': creds['username'],
        'credential': creds['password'],
      },
    ];

    final pc = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    });

    await Helper.setSpeakerphoneOn(true);

    pc.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _cleanup();
      }
    };

    pc.onIceCandidate = (candidate) {
      if (peerLogin != null && callId != null) {
        WsService.instance.send('call-ice:${jsonEncode({
              'to': peerLogin,
              'call_id': callId,
              'candidate': jsonEncode(candidate.toMap()),
            })}');
      }
    };

    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams.first;
        remoteRenderer?.srcObject = _remoteStream;
        _remoteStreamController.add(_remoteStream!);
        if (event.track.kind == 'video') {
          remoteVideoActive = true;
          _stateController.add(state);
        }
      }
    };

    return pc;
  }

  Future<void> startCall(String targetLogin, {bool video = false}) async {
    if (state != CallState.idle) {
      return;
    }

    state = CallState.calling;
    peerLogin = targetLogin;
    callId = _genCallId();
    isVideo = video;
    videoEnabled = video;
    _stateController.add(state);

    localRenderer = RTCVideoRenderer();
    remoteRenderer = RTCVideoRenderer();
    await localRenderer!.initialize();
    await remoteRenderer!.initialize();

    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': true,
    });

    if (!video) {
      _localStream!.getVideoTracks().forEach((t) => t.enabled = false);
    }

    localRenderer!.srcObject = _localStream;
    _pc = await _createPeerConnection();

    for (final track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);

    WsService.instance.send('call-offer:${jsonEncode({
          'to': targetLogin,
          'call_id': callId,
          'sdp': offer.sdp,
          'sdp_type': 'offer',
          'video': video,
        })}');
  }

  void handleIncomingOffer(Map<String, dynamic> data) {
    _pendingOffer = data;
    peerLogin = data['from'];
    callId = data['call_id'];
    isVideo = data['video'] == true || data['call_type'] == 'video';
    state = CallState.incoming;
    _stateController.add(state);
  }

  // Renegotiation — собеседник включил камеру во время звонка
  Future<void> handleRenegotiation(Map<String, dynamic> data) async {
    if (_pc == null) {
      return;
    }

    final offer = RTCSessionDescription(data['sdp'], 'offer');
    await _pc!.setRemoteDescription(offer);

    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);

    WsService.instance.send('call-answer:${jsonEncode({
          'to': peerLogin,
          'call_id': callId,
          'sdp': answer.sdp,
          'sdp_type': 'answer',
        })}');
  }

  Future<void> acceptCall() async {
    if (_pendingOffer == null || state != CallState.incoming) {
      return;
    }

    state = CallState.connected;
    _callStartedAt = DateTime.now();
    _stateController.add(state);

    localRenderer = RTCVideoRenderer();
    remoteRenderer = RTCVideoRenderer();
    await localRenderer!.initialize();
    await remoteRenderer!.initialize();

    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': true,
    });

    if (!isVideo) {
      _localStream!.getVideoTracks().forEach((t) => t.enabled = false);
      videoEnabled = false;
    } else {
      videoEnabled = true;
    }

    localRenderer!.srcObject = _localStream;
    _pc = await _createPeerConnection();

    for (final track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    final offer = RTCSessionDescription(_pendingOffer!['sdp'], 'offer');
    await _pc!.setRemoteDescription(offer);

    for (final c in _pendingCandidates) {
      await _pc!.addCandidate(c);
    }
    _pendingCandidates.clear();

    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);

    WsService.instance.send('call-answer:${jsonEncode({
          'to': peerLogin,
          'call_id': callId,
          'sdp': answer.sdp,
          'sdp_type': 'answer',
        })}');

    _pendingOffer = null;
  }

  Future<void> handleAnswer(Map<String, dynamic> data) async {
    // Если уже connected — это ответ на renegotiation
    if (state == CallState.connected) {
      if (_pc == null) return;
      final sdpType =
          (data['sdp_type'] ?? data['type'] ?? 'answer').toString();
      final normalizedType =
          (sdpType == 'call-answer') ? 'answer' : sdpType;
      final answer = RTCSessionDescription(data['sdp'], normalizedType);
      await _pc!.setRemoteDescription(answer);
      return;
    }

    int attempts = 0;
    while (_pc == null && attempts < 20) {
      await Future.delayed(const Duration(milliseconds: 100));
      attempts++;
    }
    if (_pc == null) {
      return;
    }

    final sdpType =
        (data['sdp_type'] ?? data['type'] ?? 'answer').toString();
    final normalizedType =
        (sdpType == 'call-answer') ? 'answer' : sdpType;
    final answer = RTCSessionDescription(data['sdp'], normalizedType);
    await _pc!.setRemoteDescription(answer);

    state = CallState.connected;
    _callStartedAt = DateTime.now();
    _stateController.add(state);
  }

  Future<void> handleIceCandidate(Map<String, dynamic> data) async {
    try {
      final raw = data['candidate'];
      if (raw == null) {
        return;
      }

      final Map<String, dynamic> candidateMap =
          raw is String ? jsonDecode(raw) : Map<String, dynamic>.from(raw);

      final rawIndex = candidateMap['sdpMLineIndex'];
      final index = rawIndex is int
          ? rawIndex
          : int.tryParse(rawIndex.toString()) ?? 0;

      final candidate = RTCIceCandidate(
        candidateMap['candidate'],
        candidateMap['sdpMid'],
        index,
      );

      if (_pc != null) {
        await _pc!.addCandidate(candidate);
      } else {
        _pendingCandidates.add(candidate);
      }
    } catch (_) {}
  }

  void declineCall() {
    WsService.instance.send('call-end:${jsonEncode({
          'to': peerLogin,
          'call_id': callId,
          'status': 'declined',
        })}');
    _cleanup();
  }

  void endCall() {
    if (state == CallState.idle) return;
    final duration = _callStartedAt != null
        ? DateTime.now().difference(_callStartedAt!).inSeconds
        : 0;
    WsService.instance.send('call-end:${jsonEncode({
          'to': peerLogin,
          'call_id': callId,
          'status': state == CallState.connected ? 'ended' : 'cancelled',
          'duration': duration,
        })}');
    _cleanup();
  }

  void toggleMute() {
    isMuted = !isMuted;
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !isMuted);
  }

  Future<void> toggleVideo() async {
    videoEnabled = !videoEnabled;
    _localStream?.getVideoTracks().forEach((t) => t.enabled = videoEnabled);
    if (videoEnabled) {
      localRenderer?.srcObject = _localStream;
    }
  }

  Future<void> flipCamera() async {
    final videoTracks = _localStream?.getVideoTracks();
    if (videoTracks == null || videoTracks.isEmpty) {
      return;
    }
    await Helper.switchCamera(videoTracks.first);
  }

  Future<void> _cleanup() async {
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;
    _pc?.close();
    _pc = null;
    _pendingOffer = null;
    _pendingCandidates.clear();
    localRenderer?.dispose();
    remoteRenderer?.dispose();
    localRenderer = null;
    remoteRenderer = null;
    _callStartedAt = null;
    state = CallState.idle;
    peerLogin = null;
    callId = null;
    isMuted = false;
    videoEnabled = false;
    remoteVideoActive = false;
    await Helper.setSpeakerphoneOn(false);
    _stateController.add(state);
  }

  int get callDurationSeconds => _callStartedAt != null
      ? DateTime.now().difference(_callStartedAt!).inSeconds
      : 0;

  void startListening() {
    WsService.instance.callSignalStream.listen((data) {
      final type = data['_type'];
      if (type == 'call-offer') {
        // Если уже в звонке с этим же собеседником — это renegotiation
        if (state == CallState.connected && data['call_id'] == callId) {
          handleRenegotiation(data);
        } else {
          handleIncomingOffer(data);
        }
      } else if (type == 'call-answer') {
        handleAnswer(data);
      } else if (type == 'call-ice') {
        handleIceCandidate(data);
      } else if (type == 'call-end') {
        endCall();
      } else if (type == 'call-video-on') {
        // Первое включение видео веб-версией — renegotiation offer
        handleRenegotiation(data);
      } else if (type == 'call-video-enabled') {
        // Повторное включение — трек уже согласован, просто показываем видео
        remoteVideoActive = true;
        _stateController.add(state);
      } else if (type == 'call-video-disabled') {
        // Выключение видео
        remoteVideoActive = false;
        _stateController.add(state);
      }
    });
  }
}
