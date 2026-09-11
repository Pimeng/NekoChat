import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/models.dart';

class IdentityService {
  IdentityService(this._database);
  final AppDatabase _database;
  static const _uuid = Uuid();

  Future<LocalIdentity> create(String displayName) async {
    final normalized = displayName.trim();
    if (normalized.isEmpty || normalized.length > 32) {
      throw ArgumentError('昵称长度应为 1～32 个字符');
    }
    final now = DateTime.now();
    final identity = LocalIdentity(
      deviceId: _uuid.v4(),
      displayName: normalized,
      createdAt: now,
      lastLoginAt: now,
    );
    await _database.saveIdentity(identity);
    return identity;
  }

  Future<LocalIdentity?> restore() async {
    final identity = await _database.loadIdentity();
    if (identity == null) return null;
    final restored = LocalIdentity(
      deviceId: identity.deviceId,
      displayName: identity.displayName,
      createdAt: identity.createdAt,
      lastLoginAt: DateTime.now(),
    );
    await _database.saveIdentity(restored);
    return restored;
  }
}
