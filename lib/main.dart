import 'dart:convert';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
String? _queuedAlarmPayload;
bool _isOpeningAlarmScreen = false;

Future<void> _openAlarmScreenForPayload(String payload) async {
  if (_isOpeningAlarmScreen) {
    _queuedAlarmPayload = payload;
    return;
  }

  final navigator = navigatorKey.currentState;
  if (navigator == null || !navigator.mounted) {
    _queuedAlarmPayload = payload;
    return;
  }

  try {
    final alarms = await AlarmStorage.instance.loadAlarms();
    final matched = alarms.where((alarm) => alarm.id == payload).toList();
    if (matched.isEmpty) {
      return;
    }

    _isOpeningAlarmScreen = true;
    await navigator.push(
      MaterialPageRoute(
        builder: (_) => AlarmRingingScreen(alarm: matched.first),
      ),
    );
  } catch (error) {
    debugPrint('Opening alarm screen failed: $error');
    _queuedAlarmPayload = payload;
  } finally {
    _isOpeningAlarmScreen = false;
  }
}

Future<void> _flushQueuedAlarmScreen() async {
  final payload = _queuedAlarmPayload;
  if (payload == null) {
    return;
  }

  _queuedAlarmPayload = null;
  await _openAlarmScreenForPayload(payload);
}

Future<void> main() async {
  // Initialize services before the UI starts.
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AlarmApp());

  // Do plugin setup in background so startup never blocks first frame.
  AlarmNotificationService.instance.initialize().catchError((
    Object error,
    StackTrace stackTrace,
  ) {
    debugPrint('Alarm initialization failed: $error');
    debugPrintStack(stackTrace: stackTrace);
  });

  // Also set up native alarm receive channel handler so native code can notify Flutter directly.
  const receiveChannel = MethodChannel('alarm_app/receive');
  receiveChannel.setMethodCallHandler((call) async {
    if (call.method == 'alarmTrigger') {
      final payload = call.arguments as String?;
      if (payload != null) {
        await _openAlarmScreenForPayload(payload);
      }
    }
  });

  // Ask native side if there was a pending alarm payload that arrived
  // before Dart registered the receive handler (race on cold start).
  try {
    final settingsChannel = const MethodChannel('alarm_app/settings');
    final pending = await settingsChannel.invokeMethod<String?>('fetchPendingAlarmPayload');
    if (pending != null) {
      _queuedAlarmPayload = pending;
    }
  } catch (e) {
    debugPrint('fetchPendingAlarmPayload failed: $e');
  }
}

class AlarmApp extends StatelessWidget {
  const AlarmApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seedColor = Color(0xFF5B33F5);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      title: 'Smart Alarm',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seedColor),
        scaffoldBackgroundColor: const Color(0xFFF7F8FC),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.black,
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: seedColor,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      ),
      home: const AlarmShell(),
    );
  }
}

enum AlarmDifficulty { easy, medium, hard }

extension AlarmDifficultyLabel on AlarmDifficulty {
  String get label {
    switch (this) {
      case AlarmDifficulty.easy:
        return 'Easy';
      case AlarmDifficulty.medium:
        return 'Medium';
      case AlarmDifficulty.hard:
        return 'Hard';
    }
  }

  Color get color {
    switch (this) {
      case AlarmDifficulty.easy:
        return const Color(0xFF13A54B);
      case AlarmDifficulty.medium:
        return const Color(0xFFF08A00);
      case AlarmDifficulty.hard:
        return const Color(0xFFE11D48);
    }
  }
}

class AlarmEntry {
  const AlarmEntry({
    required this.id,
    required this.notificationId,
    required this.timeOfDay,
    required this.label,
    required this.repeatDays,
    required this.difficulty,
    required this.enabled,
    required this.sound,
  });

  final String id;
  final int notificationId;
  final TimeOfDay timeOfDay;
  final String label;
  final List<bool> repeatDays;
  final AlarmDifficulty difficulty;
  final bool enabled;
  final AlarmSoundChoice sound;

  AlarmEntry copyWith({
    String? id,
    int? notificationId,
    TimeOfDay? timeOfDay,
    String? label,
    List<bool>? repeatDays,
    AlarmDifficulty? difficulty,
    bool? enabled,
    AlarmSoundChoice? sound,
  }) {
    return AlarmEntry(
      id: id ?? this.id,
      notificationId: notificationId ?? this.notificationId,
      timeOfDay: timeOfDay ?? this.timeOfDay,
      label: label ?? this.label,
      repeatDays: repeatDays ?? this.repeatDays,
      difficulty: difficulty ?? this.difficulty,
      enabled: enabled ?? this.enabled,
      sound: sound ?? this.sound,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'notificationId': notificationId,
      'hour': timeOfDay.hour,
      'minute': timeOfDay.minute,
      'label': label,
      'repeatDays': repeatDays,
      'difficulty': difficulty.index,
      'enabled': enabled,
      'sound': sound.toJson(),
    };
  }

  factory AlarmEntry.fromJson(Map<String, dynamic> json) {
    final repeatDays = (json['repeatDays'] as List<dynamic>? ?? const [])
        .map((day) => day == true)
        .toList(growable: false);
    final difficultyIndex =
        (json['difficulty'] as int?) ?? AlarmDifficulty.medium.index;
    final safeDifficultyIndex = difficultyIndex.clamp(
      0,
      AlarmDifficulty.values.length - 1,
    );

    return AlarmEntry(
      id: json['id'] as String? ?? json['notificationId'].toString(),
      notificationId:
          json['notificationId'] as int? ?? int.parse(json['id'].toString()),
      timeOfDay: TimeOfDay(
        hour: (json['hour'] as int?) ?? 7,
        minute: (json['minute'] as int?) ?? 30,
      ),
      label: json['label'] as String? ?? '',
      repeatDays: repeatDays.length == 7
          ? repeatDays
          : List<bool>.filled(7, false),
      difficulty: AlarmDifficulty.values[safeDifficultyIndex],
      enabled: json['enabled'] as bool? ?? true,
      sound: AlarmSoundChoice.fromJson(json['sound'] as Map<String, dynamic>?),
    );
  }
}

class MathQuestion {
  const MathQuestion({required this.question, required this.answer});

  final String question;
  final int answer;
}

enum AlarmSoundKind { phoneFile }

class AlarmSoundChoice {
  const AlarmSoundChoice._({
    required this.kind,
    required this.displayName,
    this.filePath,
  });

  const AlarmSoundChoice.phoneFile({
    required String displayName,
    required String filePath,
  }) : this._(
          kind: AlarmSoundKind.phoneFile,
          displayName: displayName,
          filePath: filePath,
        );

  final AlarmSoundKind kind;
  final String displayName;
  final String? filePath;

  Map<String, dynamic> toJson() {
    return {
      'kind': kind.name,
      'displayName': displayName,
      'filePath': filePath,
    };
  }

  factory AlarmSoundChoice.fromJson(Map<String, dynamic>? json) {
          final filePath = json?['filePath'] as String?;
          if (filePath != null && filePath.isNotEmpty) {
            return AlarmSoundChoice.phoneFile(
              displayName: json?['displayName'] as String? ?? _fileNameFromPath(filePath),
              filePath: filePath,
            );
    }

    return const AlarmSoundChoice.phoneFile(
      displayName: 'Choose a sound',
      filePath: '',
    );
  }

  Source toAudioSource() {
    if (kind == AlarmSoundKind.phoneFile && filePath != null && filePath!.isNotEmpty) {
      return DeviceFileSource(filePath!);
    }

    throw StateError('A phone sound file must be selected before playback.');
  }
}

class AlarmStorage {
  AlarmStorage._();

  static final AlarmStorage instance = AlarmStorage._();
  static const String _alarmsKey = 'saved_alarms';
  static const String _nextAlarmIdKey = 'next_alarm_id';

  Future<List<AlarmEntry>> loadAlarms() async {
    // Read saved alarms from local storage when the app opens.
    final preferences = await SharedPreferences.getInstance();
    final rawAlarms = preferences.getStringList(_alarmsKey) ?? const [];
    final alarms = rawAlarms
        .map(
          (item) =>
              AlarmEntry.fromJson(jsonDecode(item) as Map<String, dynamic>),
        )
        .toList(growable: false);

    final highestId = alarms.fold<int>(
      0,
      (currentMax, alarm) => max(currentMax, alarm.notificationId),
    );
    final storedNextId = preferences.getInt(_nextAlarmIdKey) ?? 1;
    if (storedNextId <= highestId) {
      await preferences.setInt(_nextAlarmIdKey, highestId + 1);
    }

    return alarms;
  }

  Future<void> saveAlarms(List<AlarmEntry> alarms) async {
    // Save the current alarm list after any add/edit/toggle/delete action.
    final preferences = await SharedPreferences.getInstance();
    final encodedAlarms = alarms
        .map((alarm) => jsonEncode(alarm.toJson()))
        .toList(growable: false);
    await preferences.setStringList(_alarmsKey, encodedAlarms);

    final highestId = alarms.fold<int>(
      0,
      (currentMax, alarm) => max(currentMax, alarm.notificationId),
    );
    final nextId = max(highestId + 1, preferences.getInt(_nextAlarmIdKey) ?? 1);
    await preferences.setInt(_nextAlarmIdKey, nextId);
  }

  Future<int> allocateAlarmId() async {
    // Generate a stable id used by Android notifications.
    final preferences = await SharedPreferences.getInstance();
    final nextId = preferences.getInt(_nextAlarmIdKey) ?? 1;
    await preferences.setInt(_nextAlarmIdKey, nextId + 1);
    return nextId;
  }
}

class AlarmNotificationService {
  AlarmNotificationService._();

  static final AlarmNotificationService instance = AlarmNotificationService._();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  bool _isInitialized = false;
  static const MethodChannel _platform = MethodChannel('alarm_app/settings');
  static const MethodChannel _nativeAlarm = MethodChannel('alarm_app/native_alarm');

  Future<void> initialize() async {
    if (_isInitialized) {
      return;
    }

    tzdata.initializeTimeZones();
    try {
      final timeZoneInfo = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timeZoneInfo.identifier));
    } catch (error, stackTrace) {
      debugPrint('Failed to resolve local timezone, using UTC: $error');
      debugPrintStack(stackTrace: stackTrace);
      tz.setLocalLocation(tz.UTC);
    }

    const initializationSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    );

    await _notifications.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) async {
        final payload = response.payload;
        if (payload == null) return;

        try {
          final alarms = await AlarmStorage.instance.loadAlarms();
          final matched = alarms.where((a) => a.id == payload).toList();
          if (matched.isNotEmpty) {
            final alarm = matched.first;
            navigatorKey.currentState?.push(
              MaterialPageRoute(builder: (_) => AlarmRingingScreen(alarm: alarm)),
            );
          }
        } catch (e) {
          debugPrint('Failed to open alarm from notification payload: $e');
        }
      },
    );

    final androidImplementation = _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    try {
      const alarmChannel = AndroidNotificationChannel(
        'smart_alarm_channel',
        'Smart Alarm',
        description: 'Scheduled alarms that keep working when the app is closed.',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      );
      const reminderChannel = AndroidNotificationChannel(
        'smart_alarm_reminder_channel_v3',
        'Alarm Reminders',
        description: 'Reminders before alarms go off.',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
      );

      await androidImplementation?.createNotificationChannel(alarmChannel);
      await androidImplementation?.createNotificationChannel(reminderChannel);
    } catch (error, stackTrace) {
      debugPrint('Notification channel setup failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    // Ask for runtime permissions needed for alarm notifications.
    try {
      await androidImplementation?.requestNotificationsPermission();
      await androidImplementation?.requestExactAlarmsPermission();
    } catch (error, stackTrace) {
      debugPrint('Notification permission request failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }

    // Provide helpers to open system settings from Dart via MethodChannel.

    _isInitialized = true;
  }

  Future<void> rescheduleAll(List<AlarmEntry> alarms) async {
    await initialize();

    // Re-register alarms after app start so background triggers continue.
    for (final alarm in alarms) {
      await scheduleAlarm(alarm);
    }
  }

  Future<void> scheduleAlarm(AlarmEntry alarm) async {
    await initialize();

    // Clear old schedules first, then register the active weekdays.
    await cancelAlarm(alarm);

    if (!alarm.enabled) {
      return;
    }

    for (var dayIndex = 0; dayIndex < alarm.repeatDays.length; dayIndex++) {
      if (!alarm.repeatDays[dayIndex]) {
        continue;
      }

      final scheduledDate = _nextWeeklyOccurrence(alarm.timeOfDay, dayIndex);
      
      // Schedule pre-alarm notifications at 10, 5, and 1 minute before using
      // the native AlarmManager path. Skip any pre-alarms that would trigger
      // in the past to avoid immediately firing them when the alarm is created.
      final now = tz.TZDateTime.now(tz.local);
      for (final minutesBefore in [10, 5, 1]) {
        final preAlarmDate = scheduledDate.subtract(Duration(minutes: minutesBefore));
        if (!preAlarmDate.isAfter(now)) {
          // Skip pre-alarm already in the past.
          continue;
        }
        try {
          await scheduleNativeAlarm(
            _notificationIdForDay(alarm.notificationId, dayIndex, minutesBefore),
            preAlarmDate.toLocal(),
            'Alarm in $minutesBefore minute${minutesBefore > 1 ? 's' : ''}',
            alarm.label,
            payload: alarm.id,
            launchAlarmUi: false,
            soundUri: alarm.sound.filePath,
          );
        } catch (e) {
          debugPrint('Native schedule for pre-alarm failed: $e');
        }
      }

      // Schedule main alarm notification via native scheduler.
      try {
        await scheduleNativeAlarm(
          _notificationIdForDay(alarm.notificationId, dayIndex),
          scheduledDate.toLocal(),
          'Smart Alarm',
          alarm.label,
          payload: alarm.id,
          launchAlarmUi: true,
          soundUri: alarm.sound.filePath,
        );
      } catch (e) {
        debugPrint('Native schedule for main alarm failed: $e');
      }
    }
  }

  Future<void> cancelAlarm(AlarmEntry alarm) async {
    await initialize();

    // Each alarm can have up to 7 scheduled notifications (one per day) plus 3 pre-alarms per day.
    for (var dayIndex = 0; dayIndex < 7; dayIndex++) {
      // Cancel pre-alarm notifications (10, 5, 1 minutes before)
      for (final minutesBefore in [10, 5, 1]) {
        final id = _notificationIdForDay(alarm.notificationId, dayIndex, minutesBefore);
        try {
          await _notifications.cancel(id: id);
        } catch (e) {
          debugPrint('Flutter cancel pre-alarm failed for $id: $e');
        }
        try {
          await cancelNativeAlarm(id);
        } catch (e) {
          debugPrint('Native cancel pre-alarm failed for $id: $e');
        }
      }

      // Cancel main alarm notification
      final mainId = _notificationIdForDay(alarm.notificationId, dayIndex);
      try {
        await _notifications.cancel(id: mainId);
      } catch (e) {
        debugPrint('Flutter cancel main alarm failed for $mainId: $e');
      }
      try {
        await cancelNativeAlarm(mainId);
      } catch (e) {
        debugPrint('Native cancel main alarm failed for $mainId: $e');
      }
    }
  }

  Future<void> cancelAll() async {
    await initialize();
    try {
      final stored = await AlarmStorage.instance.loadAlarms();
      for (final alarm in stored) {
        await cancelAlarm(alarm);
      }
    } catch (e) {
      debugPrint('Failed to cancel native alarms from storage: $e');
    }

    // Ensure flutter scheduled notifications are cleared as well.
    await _notifications.cancelAll();
  }

  Future<List<PendingNotificationRequest>> pendingNotifications() async {
    await initialize();
    return _notifications.pendingNotificationRequests();
  }
  
  Future<void> showImmediateTestNotification(AlarmEntry alarm) async {
    await initialize();
    await _notifications.show(
      id: alarm.notificationId + 9999,
      title: 'Test Alarm',
      body: alarm.label,
      notificationDetails: _alarmNotificationDetails(alarm.sound),
      payload: alarm.id,
    );
  }

  /// Schedule a quick zonedSchedule test 10 seconds from now to verify
  /// scheduled delivery on the device.
  Future<void> scheduleQuickZonedTest() async {
    await initialize();
    final now = tz.TZDateTime.now(tz.local);
    final scheduled = now.add(const Duration(seconds: 10));
    try {
      await scheduleNativeAlarm(999901, scheduled.toLocal(), 'Scheduled Test Alarm', 'scheduled test', payload: 'scheduled_test', launchAlarmUi: true);
    } catch (e) {
      debugPrint('Native quick test schedule failed: $e');
      // Fallback: try flutter scheduled notification as a best-effort.
      await _notifications.zonedSchedule(
        id: 999901,
        title: 'Scheduled Test Alarm',
        body: 'scheduled test',
        scheduledDate: scheduled,
        notificationDetails: _alarmNotificationDetails(const AlarmSoundChoice.phoneFile(displayName: 'Test', filePath: '')),
        payload: 'scheduled_test',
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
    }
  }

  Future<bool?> requestNotificationPermission() async {
    await initialize();
    final androidImpl = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    try {
      return await androidImpl?.requestNotificationsPermission();
    } catch (e) {
      debugPrint('requestNotificationPermission failed: $e');
      return null;
    }
  }

  Future<bool?> requestExactAlarmsPermission() async {
    await initialize();
    final androidImpl = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    try {
      return await androidImpl?.requestExactAlarmsPermission();
    } catch (e) {
      debugPrint('requestExactAlarmsPermission failed: $e');
      return null;
    }
  }

  Future<void> openAppSettings() async {
    try {
      await _platform.invokeMethod('openAppSettings');
    } catch (e) {
      debugPrint('openAppSettings failed: $e');
    }
  }

  Future<void> openBatterySettings() async {
    try {
      await _platform.invokeMethod('openBatterySettings');
    } catch (e) {
      debugPrint('openBatterySettings failed: $e');
    }
  }

  Future<void> scheduleNativeAlarm(
    int id,
    DateTime dateTime,
    String title,
    String body, {
    String? payload,
    bool launchAlarmUi = true,
    String? soundUri,
  }) async {
    try {
      await _platform.invokeMethod('scheduleNativeAlarm', {
        'id': id,
        'triggerAt': dateTime.millisecondsSinceEpoch,
        'title': title,
        'body': body,
        'payload': payload ?? id.toString(),
        'launchAlarmUi': launchAlarmUi,
        'soundUri': soundUri,
      });
    } catch (e) {
      debugPrint('scheduleNativeAlarm failed: $e');
    }
  }

  Future<void> cancelNativeAlarm(int id) async {
    try {
      await _platform.invokeMethod('cancelNativeAlarm', {'id': id});
    } catch (e) {
      debugPrint('cancelNativeAlarm failed: $e');
    }
  }

  Future<void> stopNativeAlarmSound() async {
    try {
      await _platform.invokeMethod('stopNativeAlarmSound');
    } catch (e) {
      debugPrint('stopNativeAlarmSound failed: $e');
    }
  }

  NotificationDetails _alarmNotificationDetails(AlarmSoundChoice sound) {
    // This is the notification channel the phone uses when the alarm fires.
    return NotificationDetails(
      android: AndroidNotificationDetails(
        'smart_alarm_channel',
        'Smart Alarm',
        channelDescription:
            'Scheduled alarms that keep working when the app is closed.',
        importance: Importance.max,
        priority: Priority.max,
        playSound: true,
        enableVibration: true,
        fullScreenIntent: true,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        category: AndroidNotificationCategory.alarm,
        ongoing: true,
        autoCancel: false,
      ),
    );
  }

  NotificationDetails _preAlarmNotificationDetails() {
    // This is the notification channel for pre-alarm reminders.
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        'smart_alarm_reminder_channel',
        'Alarm Reminders',
        channelDescription: 'Reminders before alarms go off.',
        importance: Importance.max,
        priority: Priority.max,
        playSound: true,
        enableVibration: true,
        fullScreenIntent: true,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        category: AndroidNotificationCategory.reminder,
      ),
    );
  }
}

int _notificationIdForDay(int alarmId, int dayIndex, [int minutesBefore = 0]) {
  // Keep ids deterministic so each notification can be canceled precisely.
  // Main alarm: alarmId * 100 + dayIndex
  // Pre-alarms: alarmId * 100 + dayIndex + (10/20/30 for 10/5/1 mins before)
  if (minutesBefore == 0) {
    return alarmId * 100 + dayIndex;
  }
  final offsetMap = {10: 10, 5: 20, 1: 30};
  return alarmId * 100 + dayIndex + (offsetMap[minutesBefore] ?? 0);
}

tz.TZDateTime _nextWeeklyOccurrence(TimeOfDay timeOfDay, int dayIndex) {
  // Find the next date/time for this weekday in the local timezone.
  final now = tz.TZDateTime.now(tz.local);
  var scheduled = tz.TZDateTime(
    tz.local,
    now.year,
    now.month,
    now.day,
    timeOfDay.hour,
    timeOfDay.minute,
  );
  final targetWeekday = dayIndex == 0 ? DateTime.sunday : dayIndex;

  while (scheduled.weekday != targetWeekday) {
    scheduled = scheduled.add(const Duration(days: 1));
  }

  if (scheduled.isBefore(now)) {
    scheduled = scheduled.add(const Duration(days: 7));
  }

  return scheduled;
}

class AlarmShell extends StatefulWidget {
  const AlarmShell({super.key});

  @override
  State<AlarmShell> createState() => _AlarmShellState();
}

class _AlarmShellState extends State<AlarmShell> {
  Future<void> _showPendingNotifications() async {
    final pending = await AlarmNotificationService.instance.pendingNotifications();
    if (!mounted) return;

    if (pending.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Pending Notifications'),
          content: const Text('No pending scheduled notifications found.'),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
      return;
    }

    final lines = pending.map((p) => 'id: ${p.id} | title: ${p.title ?? ''} | body: ${p.body ?? ''} | payload: ${p.payload ?? ''}').toList();
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Pending Notifications'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Text(lines.join('\n')),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
  }

  int _selectedTab = 0;
  bool _loading = true;
  final List<AlarmEntry> _alarms = [];

  @override
  void initState() {
    super.initState();
    _loadAlarms();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _flushQueuedAlarmScreen();
    });
  }

  Future<void> _loadAlarms() async {
    // Load alarms from storage and restore background schedules.
    final loadedAlarms = await AlarmStorage.instance.loadAlarms();
    await AlarmNotificationService.instance.rescheduleAll(loadedAlarms);

    if (!mounted) {
      return;
    }

    setState(() {
      _alarms
        ..clear()
        ..addAll(loadedAlarms);
      _loading = false;
    });
  }

  Future<void> _saveAlarms() async {
    // Keep storage in sync with in-memory state.
    await AlarmStorage.instance.saveAlarms(_alarms);
  }

  Future<void> _openCreateAlarm() async {
    // Open the editor and wait for the new alarm object.
    final created = await Navigator.of(context).push<AlarmEntry>(
      MaterialPageRoute(builder: (_) => const AlarmEditorScreen()),
    );

    if (created == null) {
      return;
    }

    setState(() {
      _alarms.insert(0, created);
      _selectedTab = 0;
    });

    // Schedule it in the OS and persist the updated list.
    await AlarmNotificationService.instance.scheduleAlarm(created);
    await _saveAlarms();
  }

  Future<void> _openEditAlarm(AlarmEntry alarm) async {
    // Reuse the same editor with existing alarm values.
    final updated = await Navigator.of(context).push<AlarmEntry>(
      MaterialPageRoute(builder: (_) => AlarmEditorScreen(initialAlarm: alarm)),
    );

    if (updated == null) {
      return;
    }

    setState(() {
      final index = _alarms.indexWhere((entry) => entry.id == updated.id);
      if (index >= 0) {
        _alarms[index] = updated;
      }
    });

    // Re-schedule in case time, days, label, or enabled state changed.
    await AlarmNotificationService.instance.scheduleAlarm(updated);
    await _saveAlarms();
  }

  Future<void> _deleteAlarm(String id) async {
    // Look up the matching alarm first so we can cancel all its weekday notifications.
    final alarmToRemove = _alarms.cast<AlarmEntry?>().firstWhere(
      (alarm) => alarm?.id == id,
      orElse: () => null,
    );
    if (alarmToRemove != null) {
      await AlarmNotificationService.instance.cancelAlarm(alarmToRemove);
    }

    setState(() {
      _alarms.removeWhere((alarm) => alarm.id == id);
    });

    await _saveAlarms();
  }

  Future<void> _toggleAlarm(String id, bool enabled) async {
    // Update the switch state in memory immediately for quick UI response.
    setState(() {
      final index = _alarms.indexWhere((alarm) => alarm.id == id);
      if (index >= 0) {
        _alarms[index] = _alarms[index].copyWith(enabled: enabled);
      }
    });

    final updatedAlarm = _alarms.firstWhere((alarm) => alarm.id == id);
    if (enabled) {
      await AlarmNotificationService.instance.scheduleAlarm(updatedAlarm);
    } else {
      await AlarmNotificationService.instance.cancelAlarm(updatedAlarm);
    }

    await _saveAlarms();
  }

  Future<void> _testAlarm(AlarmEntry alarm) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => AlarmRingingScreen(alarm: alarm)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: SafeArea(child: Center(child: CircularProgressIndicator())),
      );
    }

    final pages = [
      AlarmListScreen(
        alarms: _alarms,
        onAddAlarm: _openCreateAlarm,
        onEditAlarm: _openEditAlarm,
        onDeleteAlarm: _deleteAlarm,
        onToggleAlarm: _toggleAlarm,
        onTestAlarm: _testAlarm,
        onDebugPending: _showPendingNotifications,
        onSendImmediateTest: () async {
          if (_alarms.isEmpty) {
            if (!mounted) return;
            await showDialog<void>(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('No alarms'),
                content: const Text('Create an alarm first to run a test.'),
                actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
              ),
            );
            return;
          }

          // Use the first alarm as a test target.
          await AlarmNotificationService.instance.showImmediateTestNotification(_alarms.first);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Test notification sent')));
        },
      ),
      const CalendarPlaceholderScreen(),
    ];

    return Scaffold(
      body: IndexedStack(index: _selectedTab, children: pages),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Color(0xFFE8EAF2))),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                child: SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    onPressed: _openCreateAlarm,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF5430E8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Icon(Icons.add_circle_outline, size: 26),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: _BottomTabButton(
                        icon: Icons.alarm_outlined,
                        label: 'Alarm',
                        selected: _selectedTab == 0,
                        onTap: () => setState(() => _selectedTab = 0),
                      ),
                    ),
                    Expanded(
                      child: _BottomTabButton(
                        icon: Icons.calendar_month_outlined,
                        label: 'Calendar',
                        selected: _selectedTab == 1,
                        onTap: () => setState(() => _selectedTab = 1),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomTabButton extends StatelessWidget {
  const _BottomTabButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? const Color(0xFF5B33F5) : const Color(0xFF4A4A4A);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TroubleshootScreen extends StatefulWidget {
  const TroubleshootScreen({super.key});

  @override
  State<TroubleshootScreen> createState() => _TroubleshootScreenState();
}

class _TroubleshootScreenState extends State<TroubleshootScreen> {
  String _status = '';
  bool _loading = false;

  Future<void> _checkNotificationPermission() async {
    setState(() { _loading = true; _status = 'Checking...'; });
    final granted = await AlarmNotificationService.instance.requestNotificationPermission();
    setState(() { _loading = false; _status = 'Notification permission: ${granted == true ? 'granted' : 'denied/unknown'}'; });
  }

  Future<void> _checkExactAlarmsPermission() async {
    setState(() { _loading = true; _status = 'Checking...'; });
    final granted = await AlarmNotificationService.instance.requestExactAlarmsPermission();
    setState(() { _loading = false; _status = 'Exact alarms permission: ${granted == true ? 'granted' : 'denied/unknown'}'; });
  }

  Future<void> _openAppSettings() async {
    await AlarmNotificationService.instance.openAppSettings();
  }

  Future<void> _openBatterySettings() async {
    await AlarmNotificationService.instance.openBatterySettings();
  }

  Future<void> _sendImmediateTest() async {
    final alarms = await AlarmStorage.instance.loadAlarms();
    if (alarms.isEmpty) {
      if (!mounted) return;
      showDialog<void>(context: context, builder: (_) => AlertDialog(title: const Text('No alarms'), content: const Text('Create an alarm first.'), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))]));
      return;
    }
    await AlarmNotificationService.instance.showImmediateTestNotification(alarms.first);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Immediate test notification sent')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Troubleshoot')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(onPressed: _checkNotificationPermission, child: const Text('Check / Request Notification Permission')),
              const SizedBox(height: 8),
              FilledButton(onPressed: _checkExactAlarmsPermission, child: const Text('Check / Request Exact Alarms Permission')),
              const SizedBox(height: 8),
              FilledButton(onPressed: _openAppSettings, child: const Text('Open App Notification Settings')),
              const SizedBox(height: 8),
              FilledButton(onPressed: _openBatterySettings, child: const Text('Open Battery Optimization Settings')),
              const SizedBox(height: 8),
              FilledButton(onPressed: _sendImmediateTest, child: const Text('Send Immediate Test Notification')),
              const SizedBox(height: 8),
              FilledButton(onPressed: () async {
                await AlarmNotificationService.instance.scheduleQuickZonedTest();
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Scheduled zoned test set for 10s')));
              }, child: const Text('Schedule Quick Zoned Test (10s)')),
              const SizedBox(height: 8),
              FilledButton(onPressed: () async {
                final id = 999903;
                final scheduled = DateTime.now().add(const Duration(seconds: 10));
                await AlarmNotificationService.instance.scheduleNativeAlarm(id, scheduled, 'Native Scheduled Test', 'native scheduled test', payload: 'native_test');
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Scheduled native alarm for 10s')));
              }, child: const Text('Schedule Native Test (10s)')),
              const SizedBox(height: 16),
              if (_loading) const Center(child: CircularProgressIndicator()),
              if (_status.isNotEmpty) Text(_status),
            ],
          ),
        ),
      ),
    );
  }
}

class AlarmListScreen extends StatelessWidget {
  const AlarmListScreen({
    super.key,
    required this.alarms,
    required this.onAddAlarm,
    required this.onEditAlarm,
    required this.onDeleteAlarm,
    required this.onToggleAlarm,
    required this.onTestAlarm,
    required this.onDebugPending,
    required this.onSendImmediateTest,
  });

  final List<AlarmEntry> alarms;
  final VoidCallback onAddAlarm;
  final ValueChanged<AlarmEntry> onEditAlarm;
  final ValueChanged<String> onDeleteAlarm;
  final void Function(String id, bool enabled) onToggleAlarm;
  final ValueChanged<AlarmEntry> onTestAlarm;
  final VoidCallback onDebugPending;
  final VoidCallback onSendImmediateTest;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF8738F2), Color(0xFF5B33F5)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(24),
                bottomRight: Radius.circular(24),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(
                      Icons.notifications_none,
                      color: Colors.white,
                      size: 30,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Smart Alarm',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: onDebugPending,
                      icon: const Icon(Icons.bug_report, color: Colors.white),
                      tooltip: 'Show pending notifications',
                    ),
                    IconButton(
                      onPressed: onSendImmediateTest,
                      icon: const Icon(Icons.play_arrow, color: Colors.white),
                      tooltip: 'Send immediate test notification',
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TroubleshootScreen())),
                      icon: const Icon(Icons.settings, color: Colors.white),
                      tooltip: 'Troubleshoot',
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.alarm, color: Colors.white, size: 15),
                    const SizedBox(width: 6),
                    Text(
                      'Complete tasks to turn off alarms!',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.95),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${alarms.where((alarm) => alarm.enabled).length} Alarms Active',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.84),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: alarms.isEmpty
                ? _EmptyAlarmState(onAddAlarm: onAddAlarm)
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 102),
                    itemBuilder: (context, index) {
                      final alarm = alarms[index];
                      return AlarmCard(
                        alarm: alarm,
                        onChanged: (value) => onToggleAlarm(alarm.id, value),
                        onEdit: () => onEditAlarm(alarm),
                        onDelete: () => onDeleteAlarm(alarm.id),
                        onTest: () => onTestAlarm(alarm),
                      );
                    },
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemCount: alarms.length,
                  ),
          ),
        ],
      ),
    );
  }
}

class _EmptyAlarmState extends StatelessWidget {
  const _EmptyAlarmState({required this.onAddAlarm});

  final VoidCallback onAddAlarm;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 74,
              height: 74,
              decoration: BoxDecoration(
                color: const Color(0xFFE8E7FF),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF5B33F5).withValues(alpha: 0.10),
                    blurRadius: 30,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Icon(
                Icons.notifications_none,
                size: 36,
                color: Color(0xFF5B33F5),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'No Alarms Yet!',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'Create your alarm first',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Color(0xFF666A78)),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: onAddAlarm,
              child: const Text('Add New Alarm'),
            ),
          ],
        ),
      ),
    );
  }
}

class AlarmCard extends StatelessWidget {
  const AlarmCard({
    super.key,
    required this.alarm,
    required this.onChanged,
    required this.onEdit,
    required this.onDelete,
    required this.onTest,
  });

  final AlarmEntry alarm;
  final ValueChanged<bool> onChanged;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final time = _formatAlarmTime(alarm.timeOfDay);
    final days = const ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            time.hour,
                            style: const TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.w800,
                              height: 0.95,
                            ),
                          ),
                          const SizedBox(width: 2),
                          Text(
                            ':${time.minute}',
                            style: const TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.w800,
                              height: 0.95,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            time.period,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF868B9A),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        alarm.label,
                        style: const TextStyle(
                          fontSize: 15,
                          color: Color(0xFF2F3140),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: alarm.enabled,
                  onChanged: onChanged,
                  activeThumbColor: const Color(0xFF6B50E8),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (var index = 0; index < days.length; index++)
                  _DayPill(
                    label: days[index],
                    selected: alarm.repeatDays[index],
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _DifficultyChip(alarm.difficulty),
                  _SoundChip(alarm.sound),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                TextButton(onPressed: onTest, child: const Text('Test Alarm')),
                const Spacer(),
                _ActionIconButton(icon: Icons.edit_outlined, onTap: onEdit),
                const SizedBox(width: 8),
                _ActionIconButton(
                  icon: Icons.delete_outline,
                  onTap: onDelete,
                  destructive: true,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionIconButton extends StatelessWidget {
  const _ActionIconButton({
    required this.icon,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: destructive
              ? const Color(0xFFFFF0F0)
              : const Color(0xFFF4F5F8),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          icon,
          color: destructive
              ? const Color(0xFFE11D48)
              : const Color(0xFF4E5260),
          size: 18,
        ),
      ),
    );
  }
}

class _DayPill extends StatelessWidget {
  const _DayPill({required this.label, required this.selected});

  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: selected ? const Color(0xFF6E9AFF) : const Color(0xFFF1F2F6),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: selected ? Colors.white : const Color(0xFFB9BDCA),
        ),
      ),
    );
  }
}

class _DifficultyChip extends StatelessWidget {
  const _DifficultyChip(this.difficulty);

  final AlarmDifficulty difficulty;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: difficulty.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'Math - ${difficulty.label}',
        style: TextStyle(
          color: difficulty.color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SoundChip extends StatelessWidget {
  const _SoundChip(this.sound);

  final AlarmSoundChoice sound;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF2F3140).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'Sound - ${sound.displayName}',
        style: const TextStyle(
          color: Color(0xFF2F3140),
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class CalendarPlaceholderScreen extends StatelessWidget {
  const CalendarPlaceholderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SafeArea(
      bottom: false,
      child: Center(
        child: Text(
          'Calendar \nwill be added next. \n Di pa maintindihan paano ito \n pati yung notification at background running',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Color(0xFF4C5060),
          ),
        ),
      ),
    );
  }
}

class AlarmEditorScreen extends StatefulWidget {
  const AlarmEditorScreen({super.key, this.initialAlarm});

  final AlarmEntry? initialAlarm;

  @override
  State<AlarmEditorScreen> createState() => _AlarmEditorScreenState();
}

class _AlarmEditorScreenState extends State<AlarmEditorScreen> {
  late int _hour;
  late int _minute;
  late bool _isPm;
  late final TextEditingController _labelController;
  late final List<bool> _repeatDays;
  late AlarmDifficulty _difficulty;
  late AlarmSoundChoice _soundChoice;
  final AudioPlayer _previewPlayer = AudioPlayer();
  bool _testingSound = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialAlarm;
    final timeOfDay =
        initial?.timeOfDay ?? const TimeOfDay(hour: 7, minute: 30);

    _hour = _displayHour(timeOfDay.hour);
    _minute = timeOfDay.minute;
    _isPm = timeOfDay.period == DayPeriod.pm;
    _labelController = TextEditingController(
      text: initial?.label ?? 'Alarm',
    );
    _repeatDays = List<bool>.from(
      initial?.repeatDays ?? [false, true, true, true, true, true, false],
    );
    _difficulty = initial?.difficulty ?? AlarmDifficulty.medium;
    _soundChoice = initial?.sound ?? const AlarmSoundChoice.phoneFile(
      displayName: '',
      filePath: '',
    );
    _previewPlayer.setReleaseMode(ReleaseMode.stop);
  }

  @override
  void dispose() {
    _previewPlayer.dispose();
    _labelController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final label = _labelController.text.trim();
    if (label.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please add an alarm description.')),
      );
      return;
    }

    if (_soundChoice.filePath == null || _soundChoice.filePath!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please choose a sound file first.')),
      );
      return;
    }

    final normalizedHour = _normalizeHour(_hour, _isPm);
    final notificationId =
        widget.initialAlarm?.notificationId ??
        await AlarmStorage.instance.allocateAlarmId();
    final alarm = AlarmEntry(
      id:
          widget.initialAlarm?.id ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      notificationId: notificationId,
      timeOfDay: TimeOfDay(hour: normalizedHour, minute: _minute),
      label: label,
      repeatDays: List<bool>.from(_repeatDays),
      difficulty: _difficulty,
      enabled: widget.initialAlarm?.enabled ?? true,
      sound: _soundChoice,
    );

    Navigator.of(context).pop(alarm);
  }

  Future<void> _choosePhoneMusic() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['mp3', 'wav', 'm4a', 'aac', 'ogg', 'flac'],
      allowMultiple: false,
      withData: false,
    );

    final filePath = result?.files.single.path;
    if (filePath == null || filePath.isEmpty) {
      return;
    }

    setState(() {
      _soundChoice = AlarmSoundChoice.phoneFile(
        displayName: _fileNameFromPath(filePath),
        filePath: filePath,
      );
    });
  }

  Future<void> _testSound() async {
    setState(() {
      _testingSound = true;
    });

    try {
      await _previewPlayer.stop();
      await _previewPlayer.play(_soundChoice.toAudioSource());
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not play selected sound: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _testingSound = false;
        });
      }
    }
  }

  void _changeHour(int newHour) {
    setState(() {
      _hour = newHour;
    });
  }

  void _changeMinute(int newMinute) {
    setState(() {
      _minute = newMinute;
    });
  }

  void _togglePeriod(bool isPm) {
    setState(() {
      _isPm = isPm;
    });
  }

  void _toggleDay(int index) {
    setState(() {
      _repeatDays[index] = !_repeatDays[index];
    });
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.initialAlarm != null;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
        ),
        title: Text(
          isEditing ? 'Edit Alarm' : 'New Alarm',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 104),
          child: Column(
            children: [
              _SectionCard(
                child: Row(
                  children: [
                    Expanded(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _ScrollableNumberPicker(
                            value: _hour,
                            minValue: 1,
                            maxValue: 12,
                            onChanged: _changeHour,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            ':',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 8),
                          _ScrollableNumberPicker(
                            value: _minute,
                            minValue: 0,
                            maxValue: 59,
                            onChanged: _changeMinute,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      children: [
                        _PeriodButton(
                          label: 'AM',
                          selected: !_isPm,
                          onTap: () => _togglePeriod(false),
                        ),
                        const SizedBox(height: 8),
                        _PeriodButton(
                          label: 'PM',
                          selected: _isPm,
                          onTap: () => _togglePeriod(true),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // This is the short note that shows up on the alarm card and notification.
              _SectionCard(
                title: 'Alarm Description',
                child: TextField(
                  controller: _labelController,
                  decoration: const InputDecoration(
                    hintText: 'Input text here',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              // These are the days the alarm should keep repeating on.
              _SectionCard(
                title: 'Repeat Days',
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (var index = 0; index < 7; index++)
                      GestureDetector(
                        onTap: () => _toggleDay(index),
                        child: _RepeatDayCircle(
                          label: const [
                            'S',
                            'M',
                            'T',
                            'W',
                            'T',
                            'F',
                            'S',
                          ][index],
                          selected: _repeatDays[index],
                        ),
                      ),
                  ],
                ),
              ),
              // This is the alarm difficulty, which decides the math challenge later.
              _SectionCard(
                title: 'Mission/Task:',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(
                      child: Text(
                        'Math Problem',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(height: 10),
                    // This is where the question level is chosen.
                    SegmentedButton<AlarmDifficulty>(
                      segments: const [
                        ButtonSegment(
                          value: AlarmDifficulty.easy,
                          label: Text('Easy'),
                        ),
                        ButtonSegment(
                          value: AlarmDifficulty.medium,
                          label: Text('Medium'),
                        ),
                        ButtonSegment(
                          value: AlarmDifficulty.hard,
                          label: Text('Hard'),
                        ),
                      ],
                      selected: {_difficulty},
                      onSelectionChanged: (value) {
                        setState(() {
                          _difficulty = value.first;
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    // This is the little preview that shows the kind of question you will get.
                    _MathPreviewCard(difficulty: _difficulty),
                  ],
                ),
              ),
              _SectionCard(
                title: 'Choose Alarm Sound',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: 44,
                      child: FilledButton.tonal(
                        onPressed: _choosePhoneMusic,
                        child: const Text('Choose Music File'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _soundChoice.filePath == null || _soundChoice.filePath!.isEmpty
                          ? 'No sound selected yet.'
                          : 'Selected sound: ${_soundChoice.displayName}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Pick an MP3, WAV, or other supported audio file from your phone. The alarm screen will play that file.',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF666A78),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 44,
                      child: FilledButton.icon(
                        onPressed: _testingSound ? null : _testSound,
                        icon: Icon(
                          _testingSound ? Icons.graphic_eq : Icons.play_arrow,
                        ),
                        label: Text(
                          _testingSound ? 'Playing...' : 'Test Selected Sound',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          child: SizedBox(
            height: 52,
            width: double.infinity,
            child: FilledButton(
              onPressed: _save,
              child: Icon(
                isEditing ? Icons.edit : Icons.add_circle_outline,
                size: 26,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({super.key, this.title, required this.child});

  final String? title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F2FF),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE4E6FA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(title!, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
          ],
          child,
        ],
      ),
    );
  }
}

class _ScrollableNumberPicker extends StatefulWidget {
  const _ScrollableNumberPicker({
    required this.value,
    required this.onChanged,
    required this.minValue,
    required this.maxValue,
  });

  final int value;
  final ValueChanged<int> onChanged;
  final int minValue;
  final int maxValue;

  @override
  State<_ScrollableNumberPicker> createState() =>
      _ScrollableNumberPickerState();
}

class _ScrollableNumberPickerState extends State<_ScrollableNumberPicker> {
  Future<void> _showInputDialog() async {
    final controller = TextEditingController(text: widget.value.toString());
    final result = await showDialog<int>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Enter value'),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            maxLength: 2,
            decoration: InputDecoration(
              hintText: 'Between ${widget.minValue} and ${widget.maxValue}',
              border: const OutlineInputBorder(),
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final parsed = int.tryParse(controller.text.trim());
                if (parsed != null &&
                    parsed >= widget.minValue &&
                    parsed <= widget.maxValue) {
                  Navigator.pop(context, parsed);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Enter a number between ${widget.minValue} and ${widget.maxValue}',
                      ),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              },
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
    if (result != null) {
      widget.onChanged(result);
    }
  }

  void _increment() {
    if (widget.value < widget.maxValue) {
      widget.onChanged(widget.value + 1);
    }
  }

  void _decrement() {
    if (widget.value > widget.minValue) {
      widget.onChanged(widget.value - 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _showInputDialog,
      child: Column(
        children: [
          IconButton(
            onPressed: _increment,
            icon: const Icon(Icons.keyboard_arrow_up_rounded),
            visualDensity: VisualDensity.standard,
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          ),
          Container(
            width: 78,
            height: 74,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.value.toString().padLeft(2, '0'),
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _decrement,
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
            visualDensity: VisualDensity.standard,
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          ),
        ],
      ),
    );
  }
}

class _PeriodButton extends StatelessWidget {
  const _PeriodButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 58,
      child: FilledButton.tonal(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: selected ? const Color(0xFF5430E8) : Colors.white,
          foregroundColor: selected ? Colors.white : const Color(0xFF2F3140),
          padding: const EdgeInsets.symmetric(vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          side: BorderSide(
            color: selected ? const Color(0xFF5430E8) : const Color(0xFFE1E3F0),
          ),
        ),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
    );
  }
}

class _RepeatDayCircle extends StatelessWidget {
  const _RepeatDayCircle({required this.label, required this.selected});

  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: selected ? const Color(0xFF5C34F6) : Colors.white,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          color: selected ? Colors.white : const Color(0xFFC3C6D5),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _MathPreviewCard extends StatelessWidget {
  const _MathPreviewCard({required this.difficulty});

  final AlarmDifficulty difficulty;

  @override
  Widget build(BuildContext context) {
    final questions = _generateQuestions(difficulty);
    final color = difficulty.color;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Text(
              difficulty.label,
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 10),
          for (final question in questions)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                question.question,
                style: const TextStyle(color: Color(0xFF505566), fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }
}

class AlarmRingingScreen extends StatefulWidget {
  const AlarmRingingScreen({super.key, required this.alarm});

  final AlarmEntry alarm;

  @override
  State<AlarmRingingScreen> createState() => _AlarmRingingScreenState();
}

class _AlarmRingingScreenState extends State<AlarmRingingScreen> {
  late final List<MathQuestion> _questions;
  late final TextEditingController _answerController;
  late final AudioPlayer _alarmPlayer;
  late final int _questionSeed;
  int _index = 0;
  String? _errorText;
  String? _soundError;

  @override
  void initState() {
    super.initState();
    _questionSeed = Random().nextInt(1 << 32);
    _questions = _generateQuestions(widget.alarm.difficulty, count: 5, seed: _questionSeed);
    _answerController = TextEditingController();
    _alarmPlayer = AudioPlayer()..setReleaseMode(ReleaseMode.loop);
    // Stop any native playback started while the device was asleep, then
    // start Flutter's player. This avoids duplicate overlapping audio.
    Future.microtask(() async {
      try {
        await AlarmNotificationService.instance.stopNativeAlarmSound();
      } catch (_) {}
      if (mounted) await _playAlarmSound();
    });
  }

  @override
  void dispose() {
    _alarmPlayer.dispose();
    _answerController.dispose();
    super.dispose();
  }

  Future<void> _playAlarmSound() async {
    try {
      await _alarmPlayer.stop();
      await _alarmPlayer.play(widget.alarm.sound.toAudioSource());
    } catch (error) {
      if (!mounted) return;
      setState(() => _soundError = 'Sound playback failed: $error');
    }
  }

  Future<void> _stopAlarmSound() async => await _alarmPlayer.stop();

  Future<void> _submit() async {
    final parsed = int.tryParse(_answerController.text.trim());
    if (parsed == null) {
      setState(() => _errorText = 'Enter a number.');
      return;
    }
    if (parsed != _questions[_index].answer) {
      setState(() => _errorText = 'Try again.');
      return;
    }
    if (_index < _questions.length - 1) {
      setState(() { _index += 1; _errorText = null; _answerController.clear(); });
    } else {
      await _stopAlarmSound();
      try {
        await AlarmNotificationService.instance.stopNativeAlarmSound();
      } catch (_) {}
      if (mounted) Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentQuestion = _questions[_index];
    final progress = (_index + 1) / _questions.length;
    final time = _formatAlarmTime(widget.alarm.timeOfDay);

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
              decoration: const BoxDecoration(
                color: Color(0xFFE42E63),
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(26),
                  bottomRight: Radius.circular(26),
                ),
              ),
              child: Column(
                children: [
                  const Icon(Icons.notifications_none_rounded, color: Colors.white, size: 44),
                  const SizedBox(height: 10),
                  Text('${time.hour}:${time.minute} ${time.period}', style: const TextStyle(color: Colors.white, fontSize: 44, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(widget.alarm.label, style: const TextStyle(color: Colors.white, fontSize: 18)),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom + 16),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('Solve the Math Problem!', textAlign: TextAlign.center, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 6),
                      Text('${_index + 1}/${_questions.length}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, color: Color(0xFF535867))),
                      if (_soundError != null) ...[
                        const SizedBox(height: 10),
                        Text(_soundError!, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFE11D48), fontSize: 12)),
                      ],
                      const SizedBox(height: 14),
                      Container(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22), decoration: BoxDecoration(color: const Color(0xFFF1F2FF), borderRadius: BorderRadius.circular(18)), child: Text(currentQuestion.question, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800))),
                      const SizedBox(height: 14),
                      TextField(controller: _answerController, keyboardType: TextInputType.number, onSubmitted: (_) => _submit(), decoration: InputDecoration(hintText: 'Enter your answer here', errorText: _errorText, border: OutlineInputBorder(borderRadius: BorderRadius.circular(18)), contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16)), textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      ClipRRect(borderRadius: BorderRadius.circular(999), child: LinearProgressIndicator(value: progress, minHeight: 6, backgroundColor: const Color(0xFFE8E2FA), valueColor: const AlwaysStoppedAnimation(Color(0xFF5B33F5)))),
                      const SizedBox(height: 12),
                      Align(alignment: Alignment.center, child: _DifficultyChip(widget.alarm.difficulty)),
                      const SizedBox(height: 12),
                      SizedBox(height: 54, child: FilledButton(onPressed: _submit, child: const Text('Submit Answer to Stop Alarm!'))),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FormattedAlarmTime {
  final String hour;
  final String minute;
  final String period;
  const _FormattedAlarmTime({required this.hour, required this.minute, required this.period});
}

_FormattedAlarmTime _formatAlarmTime(TimeOfDay timeOfDay) {
  final displayHour = timeOfDay.hourOfPeriod == 0 ? 12 : timeOfDay.hourOfPeriod;
  return _FormattedAlarmTime(
    hour: displayHour.toString().padLeft(2, '0'),
    minute: timeOfDay.minute.toString().padLeft(2, '0'),
    period: timeOfDay.period == DayPeriod.am ? 'AM' : 'PM',
  );
}

int _displayHour(int hour24) {
  final hour = hour24 % 12;
  return hour == 0 ? 12 : hour;
}

int _normalizeHour(int displayHour, bool isPm) {
  if (displayHour == 12) {
    return isPm ? 12 : 0;
  }
  return isPm ? displayHour + 12 : displayHour;
}

String _fileNameFromPath(String filePath) {
  final sanitized = filePath.replaceAll('\\', '/');
  final index = sanitized.lastIndexOf('/');
  return index >= 0 ? sanitized.substring(index + 1) : sanitized;
}

List<MathQuestion> _generateQuestions(
  AlarmDifficulty difficulty, {
  int count = 3,
  int? seed,
}) {
  final random = seed == null ? Random() : Random(seed);
  final questions = <MathQuestion>[];

  for (var index = 0; index < count; index++) {
    final a = _nextNumber(random, difficulty);
    final b = _nextNumber(random, difficulty);
    final c = _nextNumber(random, difficulty);
    final pattern = random.nextInt(3);
    String question;
    int answer;
    switch (difficulty) {
      case AlarmDifficulty.easy:
        if (pattern == 0) {
          question = '$a + $b = ?';
          answer = a + b;
        } else if (pattern == 1) {
          question = '$a - $b = ?';
          answer = a - b;
        } else {
          question = '$a x $b = ?';
          answer = a * b;
        }
        break;
      case AlarmDifficulty.medium:
        if (pattern == 0) {
          question = '($a x $b) + $c = ?';
          answer = (a * b) + c;
        } else if (pattern == 1) {
          question = '($a + $b) x $c = ?';
          answer = (a + b) * c;
        } else {
          question = '($a x $b) - $c = ?';
          answer = (a * b) - c;
        }
        break;
      case AlarmDifficulty.hard:
        if (pattern == 0) {
          question = '($a x $b) + ($b x $c) = ?';
          answer = (a * b) + (b * c);
        } else if (pattern == 1) {
          question = '($a + $b) x ($c - 1) = ?';
          answer = (a + b) * (c - 1);
        } else {
          question = '($a x $b) - ($c + $a) = ?';
          answer = (a * b) - (c + a);
        }
        break;
    }

    questions.add(MathQuestion(question: question, answer: answer));
  }

  return questions;
}

int _nextNumber(Random random, AlarmDifficulty difficulty) {
  switch (difficulty) {
    case AlarmDifficulty.easy:
      return random.nextInt(8) + 2;
    case AlarmDifficulty.medium:
      return random.nextInt(9) + 2;
    case AlarmDifficulty.hard:
      return random.nextInt(10) + 2;
  }
}
