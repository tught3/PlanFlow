import '../models/reminder_model.dart';

abstract class ReminderRepository {
  const ReminderRepository();

  Future<List<ReminderModel>> fetchReminders(String userId);

  Future<void> saveReminder(ReminderModel reminder);
}
