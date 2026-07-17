// upgraded patient app

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_to_text.dart' as stt;

const defaultPatientApiBase = String.fromEnvironment('PATIENT_API_BASE',
    defaultValue: 'http://10.0.2.2:8001');
const _sessionIdKey = 'patient.localPatientId';
const _sessionTokenKey = 'patient.accessToken';
const _lastStatusKey = 'patient.lastStatus';
const appName = 'CareFlow';

void main() => runApp(const UrgentPatientApp());

class UrgentPatientApp extends StatelessWidget {
  const UrgentPatientApp({super.key, this.apiFactory});
  final PatientApiFactory? apiFactory;

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF176B7A);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: appName,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: primary),
        scaffoldBackgroundColor: const Color(0xFFF5F8FA),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xFFF5F8FA)),
        cardTheme: CardThemeData(
            elevation: 0,
            color: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            margin: EdgeInsets.zero),
        inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: Colors.white,
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(14))),
        filledButtonTheme: FilledButtonThemeData(
            style:
                FilledButton.styleFrom(minimumSize: const Size.fromHeight(52))),
      ),
      home: PatientHomePage(apiFactory: apiFactory),
    );
  }
}

class PatientStatus {
  const PatientStatus(
      {required this.localPatientId,
      required this.patientId,
      required this.status,
      required this.patientsAhead,
      required this.estimatedWaitRange,
      required this.submittedInformation,
      this.queueNumber,
      this.notified = false,
      this.notifiedAt,
      this.checkedInAt,
      this.serverTime,
      this.accessToken});
  final int localPatientId;
  final int patientId;
  final int? queueNumber;
  final String status;
  final int patientsAhead;
  final String estimatedWaitRange;
  final bool notified;
  final String? notifiedAt;
  final String? checkedInAt;
  final String? serverTime;
  final String? accessToken;
  final Map<String, dynamic> submittedInformation;
  bool get isFinished =>
      status.toLowerCase().contains('completed') ||
      status.toLowerCase().contains('cancelled');
  bool get isCalled =>
      notified ||
      status.toLowerCase().contains('called') ||
      status.toLowerCase().contains('consultation');
  factory PatientStatus.fromJson(Map<String, dynamic> json) => PatientStatus(
        localPatientId: _asInt(json['local_patient_id']),
        patientId: _asInt(json['patient_id']),
        queueNumber:
            json['queue_number'] == null ? null : _asInt(json['queue_number']),
        status: json['status']?.toString() ?? 'Waiting',
        patientsAhead: _asInt(json['patients_ahead']),
        estimatedWaitRange:
            json['estimated_wait_range']?.toString() ?? 'Not available',
        notified: json['notified'] == true,
        notifiedAt: json['notified_at']?.toString(),
        checkedInAt: json['checked_in_at']?.toString(),
        serverTime: json['server_time']?.toString(),
        accessToken: json['access_token']?.toString(),
        submittedInformation: Map<String, dynamic>.from(
            json['submitted_information'] as Map? ?? {}),
      );
  Map<String, dynamic> toJson() => {
        'local_patient_id': localPatientId,
        'patient_id': patientId,
        'queue_number': queueNumber,
        'status': status,
        'patients_ahead': patientsAhead,
        'estimated_wait_range': estimatedWaitRange,
        'notified': notified,
        'notified_at': notifiedAt,
        'checked_in_at': checkedInAt,
        'server_time': serverTime,
        'submitted_information': submittedInformation
      };
  static int _asInt(dynamic value) =>
      value is int ? value : int.tryParse(value?.toString() ?? '') ?? 0;
}

class ApiException implements Exception {
  const ApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;
  @override
  String toString() => message;
}

abstract class PatientApiClient {
  Future<PatientStatus> checkIn(Map<String, dynamic> payload);
  Future<PatientStatus> status(int id);
  Future<String> update(int id, Map<String, dynamic> payload);
}

class PatientApi implements PatientApiClient {
  PatientApi(this.baseUrl, {this.patientToken});
  final String baseUrl;
  final String? patientToken;
  Uri _uri(String path) =>
      Uri.parse('${baseUrl.replaceAll(RegExp(r'/$'), '')}$path');
  Future<Map<String, dynamic>> _request(String method, String path,
      {Map<String, dynamic>? body}) async {
    final headers = {'Content-Type': 'application/json'};
    if (patientToken != null && patientToken!.isNotEmpty) {
      headers['X-Patient-Token'] = patientToken!;
    }
    final client = http.Client();
    try {
      final response = await (method == 'POST'
              ? client.post(_uri(path),
                  headers: headers, body: jsonEncode(body ?? {}))
              : client.get(_uri(path), headers: headers))
          .timeout(const Duration(seconds: 10));
      final decoded = response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final detail =
            decoded is Map ? decoded['detail'] ?? response.body : response.body;
        throw ApiException(response.statusCode, detail.toString());
      }
      return Map<String, dynamic>.from(decoded as Map);
    } on TimeoutException {
      throw const ApiException(408, 'Connection timed out. Please try again.');
    } finally {
      client.close();
    }
  }

  @override
  Future<PatientStatus> checkIn(Map<String, dynamic> payload) async =>
      PatientStatus.fromJson(Map<String, dynamic>.from((await _request(
          'POST', '/patient/check-in',
          body: payload))['patient'] as Map));
  @override
  Future<PatientStatus> status(int id) async =>
      PatientStatus.fromJson(Map<String, dynamic>.from(
          (await _request('GET', '/patient/$id/status'))['patient'] as Map));
  @override
  Future<String> update(int id, Map<String, dynamic> payload) async =>
      (await _request('POST', '/patient/$id/feedback',
              body: payload))['message']
          ?.toString() ??
      'Your update was submitted.';
}

enum AppView { splash, welcome, checkIn, review, active, invalid }

typedef PatientApiFactory = PatientApiClient Function(String? patientToken);

enum PatientTab { checkIn, status, info, feedback }

class PatientHomePage extends StatefulWidget {
  const PatientHomePage({super.key, this.apiFactory});
  final PatientApiFactory? apiFactory;
  @override
  State<PatientHomePage> createState() => _PatientHomePageState();
}

class _PatientHomePageState extends State<PatientHomePage>
    with WidgetsBindingObserver {
  final storage = const FlutterSecureStorage();
  final patientIdController = TextEditingController();
  final nameController = TextEditingController();
  final ageController = TextEditingController();
  final symptomsController = TextEditingController();
  final historyController = TextEditingController();
  final updateDetailsController = TextEditingController();
  final appFeedbackController = TextEditingController();
  AppView view = AppView.splash;
  PatientTab tab = PatientTab.status;
  PatientStatus? patient;
  String? patientToken;
  bool submitting = false;
  bool refreshing = false;
  bool updating = false;
  bool appInForeground = true;
  String banner = 'Loading...';
  String? refreshError;
  DateTime? lastUpdate;
  Timer? pollTimer;
  String conditionChoice = 'No change';
  String genderChoice = 'Other';
  int appRating = 5;
  bool feedbackSubmitting = false;
  bool hasAnnouncedCall = false;
  PatientApiClient get api =>
      widget.apiFactory?.call(patientToken) ??
      PatientApi(defaultPatientApiBase, patientToken: patientToken);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_restoreSession());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    pollTimer?.cancel();
    for (final controller in [
      patientIdController,
      nameController,
      ageController,
      symptomsController,
      historyController,
      updateDetailsController,
      appFeedbackController
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    appInForeground = state == AppLifecycleState.resumed;
    if (appInForeground && view == AppView.active && tab == PatientTab.status) {
      unawaited(refreshStatus());
      _startPolling();
    } else {
      _stopPolling();
    }
  }

  Future<void> _restoreSession() async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    String? idText;
    String? token;
    String? cached;
    try {
      idText = await storage.read(key: _sessionIdKey);
      token = await storage.read(key: _sessionTokenKey);
      cached = await storage.read(key: _lastStatusKey);
    } on MissingPluginException {
      idText = null;
      token = null;
      cached = null;
    } catch (_) {
      idText = null;
      token = null;
      cached = null;
    }
    if (idText == null || token == null) {
      if (!mounted) return;
      setState(() {
        view = AppView.welcome;
        banner = '';
      });
      return;
    }
    try {
      patientToken = token;
      if (cached != null) {
        patient =
            PatientStatus.fromJson(jsonDecode(cached) as Map<String, dynamic>);
      }
      if (!mounted) return;
      setState(() {
        view = AppView.active;
        tab = PatientTab.status;
        banner = '';
      });
      await refreshStatus(localPatientId: int.parse(idText), silent: true);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        view = AppView.invalid;
        banner = error.statusCode == 403
            ? 'Saved session could not be verified. Please ask staff for help.'
            : error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        view = AppView.invalid;
        banner =
            'We could not restore your saved session. Please ask staff for help.';
      });
    }
  }

  void _startPolling() {
    _stopPolling();
    final current = patient;
    if (!appInForeground ||
        current == null ||
        current.isFinished ||
        tab != PatientTab.status) {
      return;
    }
    pollTimer = Timer.periodic(
        const Duration(seconds: 8), (_) => refreshStatus(silent: true));
  }

  void _stopPolling() {
    pollTimer?.cancel();
    pollTimer = null;
  }

  void _changeTab(PatientTab next) {
    setState(() {
      tab = next;
      if (view == AppView.review && patient != null) {
        view = AppView.active;
      }
    });
    if (next == PatientTab.status) {
      unawaited(refreshStatus());
      _startPolling();
    } else {
      _stopPolling();
    }
  }

  bool _validateForm() {
    final patientIdText = patientIdController.text.trim();
    final patientId = int.tryParse(patientIdText);
    final age = int.tryParse(ageController.text.trim());
    if (patientIdText.isNotEmpty && (patientId == null || patientId <= 0)) {
      return _failValidation('Please enter a valid patient ID, or leave it blank.');
    }
    if (nameController.text.trim().isEmpty) {
      return _failValidation('Please enter your full name.');
    }
    if (age == null || age < 0 || age > 125) {
      return _failValidation('Please enter a valid age.');
    }
    if (symptomsController.text.trim().isEmpty) {
      return _failValidation('Please describe your main symptoms.');
    }
    return true;
  }

  bool _failValidation(String message) {
    setState(() => banner = message);
    unawaited(SemanticsService.sendAnnouncement(
        View.of(context), message, TextDirection.ltr));
    return false;
  }

  void _reviewCheckIn() {
    if (_validateForm()) setState(() => view = AppView.review);
  }

  Map<String, dynamic> _checkInPayload() {
    final patientId = int.tryParse(patientIdController.text.trim());
    final payload = {
      'name': nameController.text.trim(),
      'age': int.parse(ageController.text.trim()),
      'gender': genderChoice,
      'symptoms': symptomsController.text.trim(),
      'medical_history': historyController.text.trim()
    };
    if (patientId != null && patientId > 0) {
      payload['patient_id'] = patientId;
    }
    return payload;
  }

  Future<void> submitCheckIn() async {
    if (submitting) return;
    setState(() {
      submitting = true;
      banner = 'Submitting check-in...';
    });
    try {
      final nextPatient = await api.checkIn(_checkInPayload());
      patient = nextPatient;
      patientToken = nextPatient.accessToken;
      await storage.write(
          key: _sessionIdKey, value: nextPatient.localPatientId.toString());
      await storage.write(key: _sessionTokenKey, value: patientToken);
      await storage.write(
          key: _lastStatusKey, value: jsonEncode(nextPatient.toJson()));
      _clearForm();
      if (!mounted) return;
      setState(() {
        view = AppView.active;
        tab = PatientTab.status;
        lastUpdate = DateTime.now();
        refreshError = null;
        hasAnnouncedCall = false;
        banner = 'Check-in complete.';
      });
      _startPolling();
    } catch (error) {
      if (mounted) setState(() => banner = 'Check-in failed: $error');
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  void _clearForm() {
    patientIdController.clear();
    nameController.clear();
    ageController.clear();
    symptomsController.clear();
    historyController.clear();
    genderChoice = 'Other';
  }

  Future<void> refreshStatus({int? localPatientId, bool silent = false}) async {
    final id = localPatientId ?? patient?.localPatientId;
    if (id == null || refreshing) return;
    if (!silent) setState(() => refreshing = true);
    try {
      final wasCalled = patient?.isCalled == true;
      final updated = await api.status(id);
      await storage.write(
          key: _lastStatusKey, value: jsonEncode(updated.toJson()));
      if (!mounted) return;
      setState(() {
        patient = updated;
        lastUpdate = DateTime.now();
        refreshError = null;
        if (updated.isCalled) {
          banner = 'You have been called. Please go to the care desk.';
        } else if (!silent) {
          banner = 'Status refreshed.';
        }
      });
      if (updated.isCalled && !wasCalled && !hasAnnouncedCall) {
        hasAnnouncedCall = true;
        unawaited(HapticFeedback.vibrate());
        unawaited(SemanticsService.sendAnnouncement(
            View.of(context),
            'You have been called. Please go to the care desk.',
            TextDirection.ltr));
      }
      if (updated.isFinished) {
        _stopPolling();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          refreshError = error.toString();
          banner = 'Could not refresh. Your last status is still shown.';
        });
      }
    } finally {
      if (mounted && !silent) setState(() => refreshing = false);
    }
  }

  Future<void> submitConditionUpdate() async {
    final current = patient;
    if (current == null || updating) return;
    setState(() {
      updating = true;
      banner = 'Sending update...';
    });
    try {
      final details = updateDetailsController.text.trim();
      final message = details.isEmpty
          ? '[CONDITION_UPDATE] $conditionChoice'
          : '[CONDITION_UPDATE] $conditionChoice. $details';
      await api.update(current.localPatientId,
          {'rating': 'Condition update', 'message': message});
      updateDetailsController.clear();
      if (mounted) setState(() => banner = 'Update sent.');
    } catch (error) {
      if (mounted) setState(() => banner = 'Update failed: $error');
    } finally {
      if (mounted) setState(() => updating = false);
    }
  }

  Future<void> submitAppFeedback() async {
    final current = patient;
    if (current == null || feedbackSubmitting) return;
    setState(() {
      feedbackSubmitting = true;
      banner = 'Sending feedback...';
    });
    try {
      final comment = appFeedbackController.text.trim();
      final message = comment.isEmpty
          ? '[APP_FEEDBACK] $appRating stars'
          : '[APP_FEEDBACK] $appRating stars. $comment';
      await api.update(current.localPatientId,
          {'rating': appRating.toString(), 'message': message});
      appFeedbackController.clear();
      if (mounted) setState(() => banner = 'Feedback submitted.');
    } catch (error) {
      if (mounted) setState(() => banner = 'Feedback failed: $error');
    } finally {
      if (mounted) setState(() => feedbackSubmitting = false);
    }
  }

  Future<void> clearInvalidSession() async {
    await storage.delete(key: _sessionIdKey);
    await storage.delete(key: _sessionTokenKey);
    await storage.delete(key: _lastStatusKey);
    if (mounted) {
      setState(() {
        patient = null;
        patientToken = null;
        view = AppView.welcome;
        banner = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: view == AppView.splash
          ? null
          : AppBar(title: const BrandTitle(), actions: [
              IconButton(
                  tooltip: 'Accessibility help',
                  onPressed: _showAccessibilityHelp,
                  icon: const Icon(Icons.accessibility_new))
            ]),
      body: SafeArea(child: _buildBody()),
      bottomNavigationBar: view == AppView.active ||
              (view == AppView.review && patient != null)
          ? NavigationBar(
              selectedIndex: tab.index,
              onDestinationSelected: (i) => _changeTab(PatientTab.values[i]),
              destinations: const [
                  NavigationDestination(
                      icon: Icon(Icons.edit_note_outlined), label: 'Check-in'),
                  NavigationDestination(
                      icon: Icon(Icons.confirmation_number_outlined),
                      label: 'Status'),
                  NavigationDestination(
                      icon: Icon(Icons.person_outline), label: 'My info'),
                  NavigationDestination(
                      icon: Icon(Icons.rate_review_outlined), label: 'Feedback')
                ])
          : null,
    );
  }

  Widget _buildBody() => Column(children: [
        if (view != AppView.splash && banner.isNotEmpty)
          MessageBanner(message: banner, isUrgent: patient?.isCalled == true),
        Expanded(
            child: switch (view) {
          AppView.splash => const SplashScreen(),
          AppView.welcome =>
            WelcomePage(onStart: () => setState(() => view = AppView.checkIn)),
          AppView.checkIn => CheckInPage(
              patientIdController: patientIdController,
              nameController: nameController,
              ageController: ageController,
              gender: genderChoice,
              onGenderChanged: (v) => setState(() => genderChoice = v),
              symptomsController: symptomsController,
              historyController: historyController,
              onReview: _reviewCheckIn),
          AppView.review => ReviewPage(
              data: _checkInPayload(),
              onBack: () => setState(() {
                    if (patient == null) {
                      view = AppView.checkIn;
                    } else {
                      view = AppView.active;
                      tab = PatientTab.checkIn;
                    }
                  }),
              onConfirm: submitting ? null : submitCheckIn,
              submitting: submitting),
          AppView.active => IndexedStack(index: tab.index, children: [
              CheckInPage(
                  patientIdController: patientIdController,
                  nameController: nameController,
                  ageController: ageController,
                  gender: genderChoice,
                  onGenderChanged: (v) => setState(() => genderChoice = v),
                  symptomsController: symptomsController,
                  historyController: historyController,
                  onReview: _reviewCheckIn),
              StatusPage(
                  patient: patient,
                  lastUpdate: lastUpdate,
                  refreshError: refreshError,
                  refreshing: refreshing,
                  onRefresh: () => refreshStatus()),
              MyInfoPage(patient: patient),
              FeedbackPage(
                  choice: conditionChoice,
                  detailsController: updateDetailsController,
                  appFeedbackController: appFeedbackController,
                  appRating: appRating,
                  updating: updating,
                  feedbackSubmitting: feedbackSubmitting,
                  onChoiceChanged: (v) => setState(() => conditionChoice = v),
                  onRatingChanged: (v) => setState(() => appRating = v),
                  onConditionSubmit: submitConditionUpdate,
                  onFeedbackSubmit: submitAppFeedback)
            ]),
          AppView.invalid => InvalidSessionPage(onClear: clearInvalidSession)
        })
      ]);

  void _showAccessibilityHelp() {
    showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('Accessibility support'),
                content: const Text(
                    'CareFlow supports Android text scaling, TalkBack labels, voice input, visible alerts, and haptic call alerts.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'))
                ]));
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});
  @override
  Widget build(BuildContext context) => const Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.local_hospital, size: 52),
        SizedBox(height: 16),
        Text(appName)
      ]));
}

class BrandTitle extends StatelessWidget {
  const BrandTitle({super.key});
  @override
  Widget build(BuildContext context) => const Row(children: [
        Icon(Icons.local_hospital_outlined),
        SizedBox(width: 10),
        Text(appName)
      ]);
}

class MessageBanner extends StatelessWidget {
  const MessageBanner(
      {required this.message, required this.isUrgent, super.key});
  final String message;
  final bool isUrgent;
  @override
  Widget build(BuildContext context) => Semantics(
      liveRegion: true,
      label: message,
      child: Container(
          width: double.infinity,
          color: isUrgent ? const Color(0xFFFFE2E2) : const Color(0xFFE8F3F5),
          padding: const EdgeInsets.all(16),
          child: Text(message,
              style: const TextStyle(fontWeight: FontWeight.w700))));
}

class WelcomePage extends StatelessWidget {
  const WelcomePage({required this.onStart, super.key});
  final VoidCallback onStart;
  @override
  Widget build(BuildContext context) => PageScaffold(children: [
        const Icon(Icons.health_and_safety_outlined,
            size: 56, color: Color(0xFF176B7A)),
        Text('Welcome to CareFlow',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        const NoticeCard(
            text: 'If your condition becomes severe, tell staff immediately.'),
        FilledButton.icon(
            onPressed: onStart,
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Start check-in'))
      ]);
}

class CheckInPage extends StatelessWidget {
  const CheckInPage(
      {required this.patientIdController,
      required this.nameController,
      required this.ageController,
      required this.gender,
      required this.onGenderChanged,
      required this.symptomsController,
      required this.historyController,
      required this.onReview,
      super.key});
  final TextEditingController patientIdController,
      nameController,
      ageController,
      symptomsController,
      historyController;
  final String gender;
  final ValueChanged<String> onGenderChanged;
  final VoidCallback onReview;
  @override
  Widget build(BuildContext context) => PageScaffold(children: [
        const PageTitle(
            title: 'Check-in',
            subtitle:
                'Enter your own information. You can review before submitting.'),
        const SectionHeader('Personal information'),
        AppTextField(
            controller: patientIdController,
            label: 'Patient ID (optional)',
            keyboardType: TextInputType.number),
        const Text(
          'If you have visited before, enter your patient ID so previous records can be included.',
          style: TextStyle(color: Color(0xFF667085)),
        ),
        AppTextField(controller: nameController, label: 'Full name'),
        AppTextField(
            controller: ageController,
            label: 'Age',
            keyboardType: TextInputType.number),
        DropdownButtonFormField<String>(
          value: gender,
          decoration: const InputDecoration(labelText: 'Gender'),
          items: const [
            DropdownMenuItem(value: 'Male', child: Text('Male')),
            DropdownMenuItem(value: 'Female', child: Text('Female')),
            DropdownMenuItem(value: 'Other', child: Text('Other')),
          ],
          onChanged: (value) {
            if (value != null) onGenderChanged(value);
          },
        ),
        const SectionHeader('Symptoms'),
        AppTextField(
            controller: symptomsController,
            label: 'Main symptoms',
            maxLines: 4,
            voiceInput: true),
        const SectionHeader('Relevant medical history'),
        AppTextField(
            controller: historyController,
            label: 'Medical history, medications, allergies',
            maxLines: 3,
            voiceInput: true),
        FilledButton.icon(
            onPressed: onReview,
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('Review check-in'))
      ]);
}

class ReviewPage extends StatelessWidget {
  const ReviewPage(
      {required this.data,
      required this.onBack,
      required this.onConfirm,
      required this.submitting,
      super.key});
  final Map<String, dynamic> data;
  final VoidCallback onBack;
  final VoidCallback? onConfirm;
  final bool submitting;
  @override
  Widget build(BuildContext context) => PageScaffold(children: [
        const PageTitle(
            title: 'Review before submitting',
            subtitle: 'Check your information. You can go back to edit.'),
        if (data['patient_id'] != null)
          InfoRow(label: 'Patient ID', value: data['patient_id'].toString()),
        InfoRow(label: 'Name', value: data['name'].toString()),
        InfoRow(label: 'Age', value: data['age'].toString()),
        InfoRow(label: 'Gender', value: data['gender'].toString()),
        InfoRow(label: 'Symptoms', value: data['symptoms'].toString()),
        InfoRow(
            label: 'Medical history',
            value: data['medical_history']?.toString().isEmpty ?? true
                ? 'Not provided'
                : data['medical_history'].toString()),
        Row(children: [
          Expanded(
              child: OutlinedButton(
                  onPressed: submitting ? null : onBack,
                  child: const Text('Edit'))),
          const SizedBox(width: 12),
          Expanded(
              child: FilledButton(
                  onPressed: onConfirm,
                  child:
                      Text(submitting ? 'Submitting...' : 'Confirm check-in')))
        ])
      ]);
}

class StatusPage extends StatelessWidget {
  const StatusPage(
      {required this.patient,
      required this.lastUpdate,
      required this.refreshError,
      required this.refreshing,
      required this.onRefresh,
      super.key});
  final PatientStatus? patient;
  final DateTime? lastUpdate;
  final String? refreshError;
  final bool refreshing;
  final VoidCallback onRefresh;
  @override
  Widget build(BuildContext context) {
    final current = patient;
    if (current == null) return const EmptyState(text: 'No active session.');
    return PageScaffold(children: [
      const PageTitle(
          title: 'My status',
          subtitle: 'Queue order may change based on medical urgency.'),
      StatusHero(status: current.status, called: current.isCalled),
      Wrap(spacing: 12, runSpacing: 12, children: [
        MetricTile(
            label: 'Reference',
            value: current.queueNumber?.toString() ?? 'Pending'),
        MetricTile(
            label: 'Patients ahead', value: current.patientsAhead.toString()),
        MetricTile(label: 'Estimated wait', value: current.estimatedWaitRange)
      ]),
      Text('Last updated: ${formatServerDateTime(current.serverTime, fallback: lastUpdate)}'),
      if (refreshError != null)
        NoticeCard(text: 'Refresh problem: $refreshError'),
      FilledButton.icon(
          onPressed: refreshing ? null : onRefresh,
          icon: refreshing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh),
          label: Text(refreshing ? 'Refreshing...' : 'Refresh now')),
      const NoticeCard(
          text:
              'This reference number does not guarantee treatment order. Staff may change priority based on medical urgency.')
    ]);
  }
}

class MyInfoPage extends StatelessWidget {
  const MyInfoPage({required this.patient, super.key});
  final PatientStatus? patient;

  @override
  Widget build(BuildContext context) {
    final current = patient;
    if (current == null) {
      return const EmptyState(text: 'No submitted information yet.');
    }
    return PageScaffold(children: [
      const PageTitle(
          title: 'My information',
          subtitle: 'Only your own submitted details are shown here.'),
      InfoRow(
          label: 'Name',
          value: current.submittedInformation['name']?.toString() ??
              'Not provided'),
      InfoRow(
          label: 'Age',
          value: current.submittedInformation['age']?.toString() ??
              'Not provided'),
      InfoRow(
          label: 'Symptoms',
          value: current.submittedInformation['symptoms']?.toString().isEmpty ??
                  true
              ? 'Not provided'
              : current.submittedInformation['symptoms'].toString()),
      InfoRow(
          label: 'Medical history',
          value: current.submittedInformation['medical_history']
                      ?.toString()
                      .isEmpty ??
                  true
              ? 'Not provided'
              : current.submittedInformation['medical_history'].toString()),
      InfoRow(
          label: 'Checked in',
          value: formatDateTime(parseDate(current.checkedInAt))),
      const NoticeCard(
          text:
              'For corrections or cancellation, ask front desk staff. This app does not expose the staff queue or other patient records.'),
    ]);
  }
}

class FeedbackPage extends StatelessWidget {
  const FeedbackPage(
      {required this.choice,
      required this.detailsController,
      required this.appFeedbackController,
      required this.appRating,
      required this.updating,
      required this.feedbackSubmitting,
      required this.onChoiceChanged,
      required this.onRatingChanged,
      required this.onConditionSubmit,
      required this.onFeedbackSubmit,
      super.key});
  final String choice;
  final TextEditingController detailsController;
  final TextEditingController appFeedbackController;
  final int appRating;
  final bool updating;
  final bool feedbackSubmitting;
  final ValueChanged<String> onChoiceChanged;
  final ValueChanged<int> onRatingChanged;
  final VoidCallback onConditionSubmit;
  final VoidCallback onFeedbackSubmit;

  @override
  Widget build(BuildContext context) => PageScaffold(children: [
        const PageTitle(
            title: 'Feedback', subtitle: 'Send updates or feedback.'),
        Card(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader('Condition update'),
                      const SizedBox(height: 12),
                      ConditionChoiceGrid(
                          choice: choice, onChanged: onChoiceChanged),
                      const SizedBox(height: 12),
                      AppTextField(
                          controller: detailsController,
                          label: 'Optional details',
                          maxLines: 4,
                          voiceInput: true),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                          onPressed: updating ? null : onConditionSubmit,
                          icon: const Icon(Icons.send_outlined),
                          label: Text(updating ? 'Sending...' : 'Send update')),
                    ]))),
        const NoticeCard(
            text: 'If your condition becomes severe, tell staff immediately.'),
        Card(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader('App feedback'),
                      const SizedBox(height: 12),
                      Semantics(
                          label: '$appRating out of 5 stars',
                          child: Row(
                              children: List.generate(
                                  5,
                                  (index) => IconButton(
                                      tooltip: '${index + 1} stars',
                                      onPressed: () =>
                                          onRatingChanged(index + 1),
                                      icon: Icon(
                                          index < appRating
                                              ? Icons.star
                                              : Icons.star_border,
                                          color: const Color(0xFF176B7A)))))),
                      AppTextField(
                          controller: appFeedbackController,
                          label: 'Optional comment',
                          maxLines: 3),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                          onPressed:
                              feedbackSubmitting ? null : onFeedbackSubmit,
                          icon: const Icon(Icons.rate_review_outlined),
                          label: Text(feedbackSubmitting
                              ? 'Submitting...'
                              : 'Submit feedback')),
                    ]))),
      ]);
}

class ConditionChoiceGrid extends StatelessWidget {
  const ConditionChoiceGrid(
      {required this.choice, required this.onChanged, super.key});
  final String choice;
  final ValueChanged<String> onChanged;

  static const options = [
    _ConditionOption('No change', 'No change', Icons.check_circle_outline),
    _ConditionOption('Feeling better', 'Better', Icons.trending_up),
    _ConditionOption('Getting worse', 'Worse', Icons.warning_amber_outlined),
    _ConditionOption(
        'Need assistance', 'Need help', Icons.support_agent_outlined),
  ];

  @override
  Widget build(BuildContext context) => Column(children: [
        Row(children: [
          Expanded(
              child: _ConditionChoiceTile(
                  option: options[0],
                  selected: choice == options[0].value,
                  onTap: () => onChanged(options[0].value))),
          const SizedBox(width: 12),
          Expanded(
              child: _ConditionChoiceTile(
                  option: options[1],
                  selected: choice == options[1].value,
                  onTap: () => onChanged(options[1].value))),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
              child: _ConditionChoiceTile(
                  option: options[2],
                  selected: choice == options[2].value,
                  onTap: () => onChanged(options[2].value))),
          const SizedBox(width: 12),
          Expanded(
              child: _ConditionChoiceTile(
                  option: options[3],
                  selected: choice == options[3].value,
                  onTap: () => onChanged(options[3].value))),
        ]),
      ]);
}

class _ConditionChoiceTile extends StatelessWidget {
  const _ConditionChoiceTile(
      {required this.option, required this.selected, required this.onTap});
  final _ConditionOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF176B7A);
    return Semantics(
        button: true,
        selected: selected,
        label: option.label,
        child: Material(
            color: selected ? const Color(0xFFE8F3F5) : Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(
                    color: selected ? primary : const Color(0xFFD6E1E5),
                    width: selected ? 2 : 1)),
            child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: onTap,
                child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 96),
                    child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 14),
                        child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(option.icon, color: primary),
                              const SizedBox(height: 8),
                              Text(option.label,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelLarge
                                      ?.copyWith(
                                          color: selected
                                              ? primary
                                              : Colors.black87,
                                          fontWeight: FontWeight.w700)),
                            ]))))));
  }
}

class _ConditionOption {
  const _ConditionOption(this.value, this.label, this.icon);
  final String value;
  final String label;
  final IconData icon;
}

class InvalidSessionPage extends StatelessWidget {
  const InvalidSessionPage({required this.onClear, super.key});
  final VoidCallback onClear;
  @override
  Widget build(BuildContext context) => PageScaffold(children: [
        const Icon(Icons.lock_outline, size: 52, color: Color(0xFF176B7A)),
        const PageTitle(
            title: 'Session needs help',
            subtitle: 'Your saved session could not be verified.'),
        const NoticeCard(
            text:
                'For privacy, patient records require the private token created at check-in. Ask staff for help before starting again.'),
        OutlinedButton.icon(
            onPressed: onClear,
            icon: const Icon(Icons.restart_alt),
            label: const Text('Clear saved session')),
      ]);
}

class PageScaffold extends StatelessWidget {
  const PageScaffold({required this.children, super.key});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
        itemBuilder: (context, index) => children[index],
        separatorBuilder: (context, index) => const SizedBox(height: 14),
        itemCount: children.length,
      );
}

class PageTitle extends StatelessWidget {
  const PageTitle({required this.title, required this.subtitle, super.key});
  final String title;
  final String subtitle;
  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(subtitle,
            style: Theme.of(context)
                .textTheme
                .bodyLarge
                ?.copyWith(color: Colors.black87)),
      ]);
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Text(text,
      style: Theme.of(context)
          .textTheme
          .titleMedium
          ?.copyWith(fontWeight: FontWeight.w800));
}

class AppTextField extends StatefulWidget {
  const AppTextField(
      {required this.controller,
      required this.label,
      this.maxLines = 1,
      this.keyboardType,
      this.voiceInput = false,
      super.key});
  final TextEditingController controller;
  final String label;
  final int maxLines;
  final TextInputType? keyboardType;
  final bool voiceInput;

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  late final stt.SpeechToText speech;
  bool listening = false;
  String speechBaseText = '';

  @override
  void initState() {
    super.initState();
    speech = stt.SpeechToText();
  }

  Future<void> _toggleListening() async {
    if (listening) {
      await speech.stop();
      if (mounted) setState(() => listening = false);
      return;
    }
    final available = await speech.initialize();
    if (!available) return;
    speechBaseText = widget.controller.text.trim();
    setState(() => listening = true);
    await speech.listen(onResult: (result) {
      if (!result.finalResult) return;
      final words = result.recognizedWords.trim();
      widget.controller.text = [
        if (speechBaseText.isNotEmpty) speechBaseText,
        if (words.isNotEmpty) words
      ].join(' ');
      widget.controller.selection =
          TextSelection.collapsed(offset: widget.controller.text.length);
      if (mounted) setState(() => listening = false);
    });
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: widget.controller,
        keyboardType: widget.keyboardType,
        maxLines: widget.maxLines,
        minLines: widget.maxLines > 1 ? 2 : 1,
        textInputAction: widget.maxLines > 1
            ? TextInputAction.newline
            : TextInputAction.next,
        decoration: InputDecoration(
          labelText: widget.label,
          helperText: widget.voiceInput
              ? 'Use the microphone button if speaking is easier.'
              : null,
          suffixIcon: widget.voiceInput
              ? Semantics(
                  button: true,
                  label: listening
                      ? 'Stop voice input for ${widget.label}'
                      : 'Start voice input for ${widget.label}',
                  child: IconButton(
                    tooltip:
                        listening ? 'Stop voice input' : 'Start voice input',
                    onPressed: _toggleListening,
                    icon: Icon(listening ? Icons.mic : Icons.mic_none),
                  ),
                )
              : null,
        ),
      );
}

class StatusHero extends StatelessWidget {
  const StatusHero({required this.status, required this.called, super.key});
  final String status;
  final bool called;

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        label: called
            ? 'Important status. You have been called.'
            : 'Current status. $status',
        child: Card(
          color: called ? const Color(0xFFFFE2E2) : Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(children: [
              Icon(called ? Icons.campaign_outlined : Icons.hourglass_top,
                  size: 42, color: const Color(0xFF176B7A)),
              const SizedBox(width: 16),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(called ? 'You have been called' : 'Current status',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text(status,
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w900)),
                  ])),
            ]),
          ),
        ),
      );
}

class MetricTile extends StatelessWidget {
  const MetricTile({required this.label, required this.value, super.key});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 158,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(color: Colors.black87)),
              const SizedBox(height: 8),
              Text(value,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w900)),
            ]),
          ),
        ),
      );
}

class InfoRow extends StatelessWidget {
  const InfoRow({required this.label, required this.value, super.key});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: const Color(0xFF176B7A),
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(value.isEmpty ? 'Not provided' : value,
                style: Theme.of(context).textTheme.bodyLarge),
          ]),
        ),
      );
}

class NoticeCard extends StatelessWidget {
  const NoticeCard({required this.text, super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Semantics(
        child: Card(
          color: const Color(0xFFEFF7F8),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.info_outline, color: Color(0xFF176B7A)),
              const SizedBox(width: 12),
              Expanded(child: Text(text)),
            ]),
          ),
        ),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({required this.text, super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Center(
      child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text, textAlign: TextAlign.center)));
}

DateTime? parseDate(String? value) =>
    value == null ? null : DateTime.tryParse(value);

String formatDateTime(DateTime? value) {
  if (value == null) return 'Not available';
  final local = value.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} $hour:$minute';
}

String formatServerDateTime(String? value, {DateTime? fallback}) {
  if (value == null || value.isEmpty) return formatDateTime(fallback);
  final normalized = value.replaceFirst('T', ' ');
  return normalized.length >= 16 ? normalized.substring(0, 16) : normalized;
}

void unawaited(Future<void> future) {}
