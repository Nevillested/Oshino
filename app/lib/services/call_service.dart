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
    print('LOG [turn] fetching credentials...');
    final resp = await http.get(
      Uri.parse('https://oshino.space/turn-credentials'),
      headers: ApiService.authHeaders,
    );
    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body);
      print('LOG [turn] got credentials: ${data['urls']}');
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

    print('LOG [pc] creating peer connection...');
    final pc = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    });
    print('LOG [pc] peer connection created');

    await Helper.setSpeakerphoneOn(true);

    pc.onSignalingState = (s) {
      print('LOG [pc] signalingState: $s');
    };

    pc.onIceGatheringState = (s) {
      print('LOG [pc] iceGatheringState: $s');
    };

    pc.onIceConnectionState = (s) {
      print('LOG [pc] iceConnectionState: $s');
    };

    pc.onConnectionState = (s) {
      print('LOG [pc] connectionState: $s');
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        print('LOG [pc] connection lost -> cleanup');
        _cleanup();
      }
    };

    pc.onIceCandidate = (candidate) {
      print('LOG [ice] sending candidate: ${candidate.candidate?.substring(0, 50)}');
      if (peerLogin != null && callId != null) {
        WsService.instance.send('call-ice:${jsonEncode({
              'to': peerLogin,
              'call_id': callId,
              'candidate': jsonEncode(candidate.toMap()),
            })}');
      }
    };

    pc.onTrack = (event) {
      print('LOG [track] onTrack kind=${event.track.kind} '
          'streams=${event.streams.length} '
          'muted=${event.track.muted} '
          'enabled=${event.track.enabled}');
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams.first;
        print('LOG [track] setting remoteRenderer.srcObject, '
            'renderer=${remoteRenderer != null}');
        remoteRenderer?.srcObject = _remoteStream;
        _remoteStreamController.add(_remoteStream!);
        if (event.track.kind == 'video') {
          remoteVideoActive = true;
          print('LOG [track] remoteVideoActive = true -> notify UI');
          _stateController.add(state);
        }
      } else {
        print('LOG [track] WARNING: no streams in onTrack event!');
      }
    };

    return pc;
  }

  Future<void> startCall(String targetLogin, {bool video = false}) async {
    print('LOG [call] startCall to=$targetLogin video=$video');
    if (state != CallState.idle) {
      print('LOG [call] startCall ignored: state=$state');
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
    print('LOG [call] localStream: audio=${_localStream!.getAudioTracks().length} '
        'video=${_localStream!.getVideoTracks().length}');

    if (!video) {
      _localStream!.getVideoTracks().forEach((t) => t.enabled = false);
      print('LOG [call] video disabled (audio call)');
    }

    localRenderer!.srcObject = _localStream;
    _pc = await _createPeerConnection();

    for (final track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
      print('LOG [call] addTrack kind=${track.kind} enabled=${track.enabled}');
    }

    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    print('LOG [call] offer created sdp_length=${offer.sdp?.length}');

    WsService.instance.send('call-offer:${jsonEncode({
          'to': targetLogin,
          'call_id': callId,
          'sdp': offer.sdp,
          'sdp_type': 'offer',
          'video': video,
        })}');
  }

  void handleIncomingOffer(Map<String, dynamic> data) {
    print('LOG [incoming] offer from=${data['from']} '
        'call_id=${data['call_id']} '
        'video=${data['video']} '
        'call_type=${data['call_type']} '
        'sdp_length=${data['sdp']?.length}');
    _pendingOffer = data;
    peerLogin = data['from'];
    callId = data['call_id'];
    isVideo = data['video'] == true || data['call_type'] == 'video';
    print('LOG [incoming] isVideo=$isVideo');
    state = CallState.incoming;
    _stateController.add(state);
  }

  // Renegotiation — собеседник включил камеру во время звонка
  Future<void> handleRenegotiation(Map<String, dynamic> data) async {
    print('LOG [renegotiation] received from=${data['from']} '
        'sdp_length=${data['sdp']?.length}');
    if (_pc == null) {
      print('LOG [renegotiation] ERROR: _pc is null');
      return;
    }

    final offer = RTCSessionDescription(data['sdp'], 'offer');
    await _pc!.setRemoteDescription(offer);
    print('LOG [renegotiation] setRemoteDescription done');

    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);
    print('LOG [renegotiation] answer created sdp_length=${answer.sdp?.length}');

    WsService.instance.send('call-answer:${jsonEncode({
          'to': peerLogin,
          'call_id': callId,
          'sdp': answer.sdp,
          'sdp_type': 'answer',
        })}');
    print('LOG [renegotiation] answer sent');
  }

  Future<void> acceptCall() async {
    print('LOG [accept] accepting call isVideo=$isVideo');
    if (_pendingOffer == null || state != CallState.incoming) {
      print('LOG [accept] ignored: pendingOffer=${_pendingOffer != null} state=$state');
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
    print('LOG [accept] localStream: audio=${_localStream!.getAudioTracks().length} '
        'video=${_localStream!.getVideoTracks().length}');

    if (!isVideo) {
      _localStream!.getVideoTracks().forEach((t) => t.enabled = false);
      videoEnabled = false;
      print('LOG [accept] video disabled (audio call)');
    } else {
      videoEnabled = true;
      print('LOG [accept] video enabled');
    }

    localRenderer!.srcObject = _localStream;
    _pc = await _createPeerConnection();

    for (final track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
      print('LOG [accept] addTrack kind=${track.kind} enabled=${track.enabled}');
    }

    print('LOG [accept] setRemoteDescription type=offer '
        'sdp_length=${_pendingOffer!['sdp']?.length}');
    final offer = RTCSessionDescription(_pendingOffer!['sdp'], 'offer');
    await _pc!.setRemoteDescription(offer);
    print('LOG [accept] remoteDescription set');

    print('LOG [accept] applying ${_pendingCandidates.length} pending ICE candidates');
    for (final c in _pendingCandidates) {
      await _pc!.addCandidate(c);
    }
    _pendingCandidates.clear();

    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);
    print('LOG [accept] answer created sdp_length=${answer.sdp?.length}');

    WsService.instance.send('call-answer:${jsonEncode({
          'to': peerLogin,
          'call_id': callId,
          'sdp': answer.sdp,
          'sdp_type': 'answer',
        })}');
    print('LOG [accept] sending call-answer');

    _pendingOffer = null;
  }

  Future<void> handleAnswer(Map<String, dynamic> data) async {
    print('LOG [answer] received sdp_length=${data['sdp']?.length} '
        'sdp_type=${data['sdp_type']} type=${data['type']} '
        'current_state=$state');

    // Если уже connected — это ответ на renegotiation
    if (state == CallState.connected) {
      print('LOG [answer] renegotiation answer');
      if (_pc == null) return;
      final sdpType =
          (data['sdp_type'] ?? data['type'] ?? 'answer').toString();
      final normalizedType =
          (sdpType == 'call-answer') ? 'answer' : sdpType;
      final answer = RTCSessionDescription(data['sdp'], normalizedType);
      await _pc!.setRemoteDescription(answer);
      print('LOG [answer] renegotiation remoteDescription set');
      return;
    }

    int attempts = 0;
    while (_pc == null && attempts < 20) {
      await Future.delayed(const Duration(milliseconds: 100));
      attempts++;
      print('LOG [answer] waiting for _pc, attempt=$attempts');
    }
    if (_pc == null) {
      print('LOG [answer] ERROR: _pc still null');
      return;
    }

    final sdpType =
        (data['sdp_type'] ?? data['type'] ?? 'answer').toString();
    final normalizedType =
        (sdpType == 'call-answer') ? 'answer' : sdpType;
    print('LOG [answer] setRemoteDescription type=$normalizedType');
    final answer = RTCSessionDescription(data['sdp'], normalizedType);
    await _pc!.setRemoteDescription(answer);
    print('LOG [answer] remoteDescription set');

    state = CallState.connected;
    _callStartedAt = DateTime.now();
    print('LOG [answer] state -> connected');
    _stateController.add(state);
  }

  Future<void> handleIceCandidate(Map<String, dynamic> data) async {
    try {
      final raw = data['candidate'];
      if (raw == null) {
        print('LOG [ice] WARNING: candidate is null');
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
        print('LOG [ice] added: ${candidateMap['candidate']?.toString().substring(0, 40)}');
      } else {
        _pendingCandidates.add(candidate);
        print('LOG [ice] queued (pc not ready), total=${_pendingCandidates.length}');
      }
    } catch (e) {
      print('LOG [ice] ERROR: $e');
    }
  }

  void declineCall() {
    print('LOG [call] declineCall');
    WsService.instance.send('call-end:${jsonEncode({
          'to': peerLogin,
          'call_id': callId,
          'status': 'declined',
        })}');
    _cleanup();
  }

  void endCall() {
    print('LOG [call] endCall state=$state');
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
    print('LOG [call] toggleMute isMuted=$isMuted');
  }

  Future<void> toggleVideo() async {
    videoEnabled = !videoEnabled;
    _localStream?.getVideoTracks().forEach((t) => t.enabled = videoEnabled);
    if (videoEnabled) {
      localRenderer?.srcObject = _localStream;
    }
    print('LOG [call] toggleVideo videoEnabled=$videoEnabled');
  }

  Future<void> flipCamera() async {
    final videoTracks = _localStream?.getVideoTracks();
    if (videoTracks == null || videoTracks.isEmpty) {
      print('LOG [call] flipCamera: no video tracks');
      return;
    }
    await Helper.switchCamera(videoTracks.first);
    print('LOG [call] flipCamera done');
  }

  Future<void> _cleanup() async {
    print('LOG [call] cleanup start');
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
    print('LOG [call] cleanup done');
  }

  int get callDurationSeconds => _callStartedAt != null
      ? DateTime.now().difference(_callStartedAt!).inSeconds
      : 0;

  void startListening() {
    print('LOG [call] startListening');
    WsService.instance.callSignalStream.listen((data) {
      print('LOG [signal] received type=${data['_type']} '
          'from=${data['from']} call_id=${data['call_id']}');
      final type = data['_type'];
      if (type == 'call-offer') {
        // Если уже в звонке с этим же собеседником — это renegotiation
        if (state == CallState.connected &&
            data['call_id'] == callId) {
          print('LOG [signal] renegotiation offer detected');
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
  print('LOG [signal] call-video-on: renegotiation from web');
  handleRenegotiation(data);
} else if (type == 'call-video-enabled') {
  // Повторное включение — трек уже согласован, просто показываем видео
  print('LOG [signal] call-video-enabled');
  remoteVideoActive = true;
  _stateController.add(state);
} else if (type == 'call-video-disabled') {
  // Выключение видео
  print('LOG [signal] call-video-disabled');
  remoteVideoActive = false;
  _stateController.add(state);
}
    });
  }
}