class OshinoMessage {
  final int id;
  final bool own;
  final String text;
  final String createdAt;
  final String? imageId;
  final String? audioId;
  final int? audioDuration;
  final String? replyPreview;
  final String? replyFromLogin;
  final int? replyToId;
  final String? forwardedFrom;
  final String? callType;
  final String? callStatus;
  final int? callDuration;
  final bool isRead;
  final bool pending;
  final List<Map<String, String>> reactions;

  const OshinoMessage({
    required this.id,
    required this.own,
    required this.text,
    required this.createdAt,
    this.imageId,
    this.audioId,
    this.audioDuration,
    this.replyPreview,
    this.replyFromLogin,
    this.replyToId,
    this.forwardedFrom,
    this.callType,
    this.callStatus,
    this.callDuration,
    this.isRead = false,
    this.pending = false,
    this.reactions = const [],
  });

  OshinoMessage copyWith({
    int? id,
    bool? own,
    String? text,
    String? createdAt,
    String? imageId,
    String? audioId,
    int? audioDuration,
    String? replyPreview,
    String? replyFromLogin,
    int? replyToId,
    String? forwardedFrom,
    String? callType,
    String? callStatus,
    int? callDuration,
    bool? isRead,
    bool? pending,
    List<Map<String, String>>? reactions,
  }) =>
      OshinoMessage(
        id: id ?? this.id,
        own: own ?? this.own,
        text: text ?? this.text,
        createdAt: createdAt ?? this.createdAt,
        imageId: imageId ?? this.imageId,
        audioId: audioId ?? this.audioId,
        audioDuration: audioDuration ?? this.audioDuration,
        replyPreview: replyPreview ?? this.replyPreview,
        replyFromLogin: replyFromLogin ?? this.replyFromLogin,
        replyToId: replyToId ?? this.replyToId,
        forwardedFrom: forwardedFrom ?? this.forwardedFrom,
        callType: callType ?? this.callType,
        callStatus: callStatus ?? this.callStatus,
        callDuration: callDuration ?? this.callDuration,
        isRead: isRead ?? this.isRead,
        pending: pending ?? this.pending,
        reactions: reactions ?? this.reactions,
      );

  Map<String, List<String>> get reactionsGrouped {
    final result = <String, List<String>>{};
    for (final r in reactions) {
      final emoji = r['emoji'] ?? '';
      final from = r['from'] ?? '';
      if (emoji.isNotEmpty) result.putIfAbsent(emoji, () => []).add(from);
    }
    return result;
  }

  factory OshinoMessage.fromJson(Map<String, dynamic> json) {
    String? replyPreview;
    String? replyFromLogin;
    final rp = json['reply_preview'];
    if (rp is Map) {
      replyFromLogin = rp['from']?.toString();
      replyPreview = rp['text']?.toString();
    } else if (rp is String) {
      replyPreview = rp;
    }

    final rawReactions = json['reactions'];
    final reactions = <Map<String, String>>[];
    if (rawReactions is List) {
      for (final r in rawReactions) {
        if (r is Map) {
          final e = r['emoji']?.toString() ?? '';
          final f = r['from']?.toString() ?? '';
          if (e.isNotEmpty) reactions.add({'emoji': e, 'from': f});
        }
      }
    }

    return OshinoMessage(
      id: (json['id'] as num?)?.toInt() ?? 0,
      own: json['own'] == true,
      text: json['text']?.toString() ?? json['content']?.toString() ?? '',
      createdAt: json['created_at']?.toString() ??
          json['createdAt']?.toString() ?? '',
      imageId: json['image_id']?.toString(),
      audioId: json['audio_id']?.toString(),
      audioDuration: (json['audio_duration'] as num?)?.toInt(),
      replyPreview: replyPreview,
      replyFromLogin: replyFromLogin,
      replyToId: (json['reply_to_id'] as num?)?.toInt(),
      forwardedFrom: json['forwarded_from']?.toString(),
      callType: json['call_type']?.toString(),
      callStatus: json['call_status']?.toString(),
      callDuration: (json['call_duration'] as num?)?.toInt(),
      isRead: json['is_read'] == true || json['isRead'] == true,
      pending: json['pending'] == true,
      reactions: reactions,
    );
  }
}