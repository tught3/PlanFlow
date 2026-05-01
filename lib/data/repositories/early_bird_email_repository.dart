import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/early_bird_email_model.dart';

enum EarlyBirdSignupStatus {
  submitted,
}

class EarlyBirdSignupResult {
  const EarlyBirdSignupResult({
    required this.email,
    required this.status,
  });

  final String email;
  final EarlyBirdSignupStatus status;

  bool get isSuccess => true;
}

abstract class EarlyBirdEmailRepository {
  const EarlyBirdEmailRepository();

  factory EarlyBirdEmailRepository.supabase({SupabaseClient? client}) =
      SupabaseEarlyBirdEmailRepository;

  Future<EarlyBirdSignupResult> saveEmail(String email);
}

class SupabaseEarlyBirdEmailRepository extends EarlyBirdEmailRepository {
  SupabaseEarlyBirdEmailRepository({
    SupabaseClient? client,
    EarlyBirdEmailGateway? gateway,
  }) : _gateway = gateway ??
            SupabaseEarlyBirdEmailGateway(
              client: client ?? Supabase.instance.client,
            );

  final EarlyBirdEmailGateway _gateway;

  @override
  Future<EarlyBirdSignupResult> saveEmail(String email) async {
    final normalizedEmail = EarlyBirdEmailModel.normalizeEmail(email);
    if (!EarlyBirdEmailModel.isValidEmail(normalizedEmail)) {
      throw ArgumentError.value(email, 'email', 'A valid email is required.');
    }

    await _gateway.submitEmail(normalizedEmail);
    return EarlyBirdSignupResult(
      email: normalizedEmail,
      status: EarlyBirdSignupStatus.submitted,
    );
  }
}

abstract class EarlyBirdEmailGateway {
  Future<void> submitEmail(String email);
}

class SupabaseEarlyBirdEmailGateway implements EarlyBirdEmailGateway {
  SupabaseEarlyBirdEmailGateway({required SupabaseClient client})
      : _client = client;

  static const String tableName = 'early_bird_emails';
  static const String functionName = 'submit_early_bird_email';

  final SupabaseClient _client;

  @override
  Future<void> submitEmail(String email) async {
    await _client.rpc(
      functionName,
      params: <String, dynamic>{'input_email': email},
    );
  }
}
