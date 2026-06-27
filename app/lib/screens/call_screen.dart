import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/call_service.dart';
import 'dart:async';

class CallScreen extends StatefulWidget {
  final String peerLogin;
  final String displayName;
  final bool isVideo;
  final bool isIncoming;

  const CallScreen({
    super.key,
    required this.peerLogin,
    required this.displayName,
    required this.isVideo,
    required this.isIncoming,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final _cs = CallService.instance;
  int _seconds = 0;
  bool _timerStarted = false;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();

    _cs.stateStream.listen((state) {
      if (!mounted) return;
      setState(() {});
      if (state == CallState.idle) {
        _pollTimer?.cancel();
        Navigator.of(context).pop();
      }
      if (state == CallState.connected && !_timerStarted) {
        _startTimer();
      }
    });

    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      if (_cs.state == CallState.idle) {
        _pollTimer?.cancel();
        Navigator.of(context).pop();
        return;
      }
      if (_cs.state == CallState.connected && !_timerStarted) {
        _startTimer();
      }
      setState(() {});
    });

    if (_cs.state == CallState.connected && !_timerStarted) {
      _startTimer();
    }
  }

  void _startTimer() {
    if (_timerStarted) return;
    _timerStarted = true;
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted || _cs.state != CallState.connected) return false;
      setState(() => _seconds++);
      return true;
    });
  }

  String _formatDuration() {
    final m = _seconds ~/ 60;
    final s = _seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  String _statusText() {
    switch (_cs.state) {
      case CallState.calling:
        return 'Вызов...';
      case CallState.incoming:
        return widget.isVideo ? 'Входящий видеозвонок' : 'Входящий звонок';
      case CallState.connected:
        return _formatDuration();
      default:
        return '';
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0d0d1a),
      body: Stack(
        children: [
          // Удалённое видео — всегда в дереве, видимость через Opacity
          if (_cs.remoteRenderer != null)
            Positioned.fill(
              child: Opacity(
                opacity: _cs.remoteVideoActive ? 1.0 : 0.0,
                child: RTCVideoView(
                  _cs.remoteRenderer!,
                  objectFit:
                      RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),
            ),

          // Локальное видео — в углу когда камера включена
          if (_cs.localRenderer != null)
            Positioned(
              right: 16,
              top: 80,
              width: 100,
              height: 140,
              child: Opacity(
                opacity: _cs.videoEnabled ? 1.0 : 0.0,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: RTCVideoView(
                    _cs.localRenderer!,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit
                        .RTCVideoViewObjectFitCover,
                  ),
                ),
              ),
            ),

          SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 60),
                Text(
                  widget.displayName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                if (_cs.state != CallState.connected)
                  Text(
                    _statusText(),
                    style: const TextStyle(
                        color: Color(0xFFaaaaaa), fontSize: 16),
                  ),
                if (_cs.state == CallState.connected)
                  Text(
                    _formatDuration(),
                    style: const TextStyle(
                        color: Color(0xFF4a90e2), fontSize: 16),
                  ),
                const Spacer(),
                if (_cs.state == CallState.incoming)
                  _buildIncomingButtons()
                else
                  _buildActiveButtons(),
                const SizedBox(height: 48),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIncomingButtons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _CallBtn(
          color: const Color(0xFFe74c3c),
          icon: Icons.call_end,
          iconSize: 28,
          onTap: () => _cs.declineCall(),
        ),
        const SizedBox(width: 40),
        _CallBtn(
          color: const Color(0xFF2ecc71),
          icon: Icons.call,
          iconSize: 28,
          onTap: () => _cs.acceptCall(),
        ),
      ],
    );
  }

  Widget _buildActiveButtons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _CallBtn(
          color: const Color(0xFFe74c3c),
          icon: Icons.call_end,
          iconSize: 28,
          onTap: () => _cs.endCall(),
        ),
        const SizedBox(width: 20),
        _CallBtn(
          color: _cs.isMuted
              ? const Color(0xFF5a3d3d)
              : const Color(0xFF444444),
          icon: _cs.isMuted ? Icons.mic_off : Icons.mic,
          iconSize: 26,
          onTap: () {
            _cs.toggleMute();
            setState(() {});
          },
        ),
        const SizedBox(width: 20),
        _CallBtn(
          color: _cs.videoEnabled
              ? const Color(0xFF2a5298)
              : const Color(0xFF444444),
          icon: _cs.videoEnabled ? Icons.videocam : Icons.videocam_off,
          iconSize: 26,
          onTap: () async {
            await _cs.toggleVideo();
            setState(() {});
          },
        ),
        if (_cs.videoEnabled) ...[
          const SizedBox(width: 20),
          _CallBtn(
            color: const Color(0xFF444444),
            icon: Icons.flip_camera_android,
            iconSize: 26,
            onTap: () async {
              await _cs.flipCamera();
            },
          ),
        ],
      ],
    );
  }
}

class _CallBtn extends StatelessWidget {
  final Color color;
  final IconData icon;
  final double iconSize;
  final VoidCallback onTap;

  const _CallBtn({
    required this.color,
    required this.icon,
    required this.iconSize,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: iconSize),
      ),
    );
  }
}