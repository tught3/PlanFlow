class EarlyBirdEmailModel {
  const EarlyBirdEmailModel({
    required this.email,
    this.createdAt,
  });

  factory EarlyBirdEmailModel.fromJson(Map<String, dynamic> json) {
    return EarlyBirdEmailModel(
      email: normalizeEmail(_requiredStringValue(json['email'], 'email')),
      createdAt: _dateTimeValue(json['created_at']),
    );
  }

  final String email;
  final DateTime? createdAt;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'email': normalizeEmail(email),
      if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
    };
  }

  static String normalizeEmail(String value) {
    return value.trim().toLowerCase();
  }

  static bool isValidEmail(String value) {
    final email = normalizeEmail(value);
    if (email.length > 254) {
      return false;
    }
    return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email);
  }

  static String _requiredStringValue(Object? value, String fieldName) {
    final text = value?.toString() ?? '';
    if (text.isEmpty) {
      throw StateError('Missing required field: $fieldName');
    }
    return text;
  }

  static DateTime? _dateTimeValue(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is DateTime) {
      return value;
    }
    final text = value.toString();
    if (text.isEmpty) {
      return null;
    }
    return DateTime.parse(text);
  }
}
