import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:urgent_care_patient_app/main.dart';

class FakePatientApi implements PatientApiClient {
  int nextId = 1;
  bool failNextCheckIn = false;
  PatientStatus? currentPatient;
  final statusRequests = <int>[];
  final updates = <Map<String, dynamic>>[];

  @override
  Future<PatientStatus> checkIn(Map<String, dynamic> payload) async {
    if (failNextCheckIn) {
      failNextCheckIn = false;
      throw const ApiException(500, 'temporary check-in failure');
    }
    final id = nextId++;
    currentPatient = PatientStatus(
      localPatientId: id,
      patientId: 1000 + id,
      queueNumber: id,
      status: 'Waiting',
      patientsAhead: id,
      estimatedWaitRange: '${id * 10}-${id * 10 + 10} minutes',
      checkedInAt: '2026-07-06T09:3$id:00',
      accessToken: 'token-$id',
      submittedInformation: Map<String, dynamic>.from(payload),
    );
    return currentPatient!;
  }

  @override
  Future<PatientStatus> status(int id) async {
    statusRequests.add(id);
    final patient = currentPatient;
    if (patient == null || patient.localPatientId != id) {
      throw const ApiException(403, 'invalid session');
    }
    currentPatient = PatientStatus(
      localPatientId: patient.localPatientId,
      patientId: patient.patientId,
      queueNumber: patient.queueNumber,
      status: patient.status,
      patientsAhead: patient.patientsAhead,
      estimatedWaitRange: patient.estimatedWaitRange,
      checkedInAt: patient.checkedInAt,
      accessToken: patient.accessToken,
      submittedInformation: patient.submittedInformation,
    );
    return currentPatient!;
  }

  @override
  Future<String> update(int id, Map<String, dynamic> payload) async {
    updates.add({'id': id, ...payload});
    return 'ok';
  }
}

void main() {
  late FakePatientApi api;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    api = FakePatientApi();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(UrgentPatientApp(apiFactory: (_) => api));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();
  }

  Future<void> openInitialCheckIn(WidgetTester tester) async {
    await tester.tap(find.text('Start check-in'));
    await tester.pumpAndSettle();
  }

  Future<void> submitVisibleCheckIn(
    WidgetTester tester, {
    required String name,
    required String age,
    required String symptoms,
  }) async {
    await tester.enterText(find.widgetWithText(TextField, 'Full name'), name);
    await tester.enterText(find.widgetWithText(TextField, 'Age'), age);
    await tester.scrollUntilVisible(find.text('Main symptoms'), 500,
        scrollable: find.byType(Scrollable).last);
    await tester.enterText(
        find.widgetWithText(TextField, 'Main symptoms'), symptoms);
    await tester.scrollUntilVisible(find.text('Review check-in'), 500,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('Review check-in'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Confirm check-in'), 500,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('Confirm check-in'));
    await tester.pumpAndSettle();
  }

  testWidgets('startup shows CareFlow without exposing API details',
      (tester) async {
    await pumpApp(tester);

    expect(find.text('Welcome to CareFlow'), findsOneWidget);
    expect(find.text('Start check-in'), findsOneWidget);
    expect(find.textContaining('10.0.2.2'), findsNothing);
    expect(find.textContaining('Backend'), findsNothing);
    expect(find.textContaining('Care Queue Patient'), findsNothing);
  });

  testWidgets('bottom navigation contains exactly four tabs after check-in',
      (tester) async {
    await pumpApp(tester);
    await openInitialCheckIn(tester);
    await submitVisibleCheckIn(tester,
        name: 'Alex Patient', age: '31', symptoms: 'Sore throat');

    expect(find.byType(NavigationDestination), findsNWidgets(4));
    expect(find.text('Check-in'), findsOneWidget);
    expect(find.text('Status'), findsOneWidget);
    expect(find.text('My info'), findsOneWidget);
    expect(find.text('Feedback'), findsOneWidget);
  });

  testWidgets('successful check-in clears the form and opens Status',
      (tester) async {
    await pumpApp(tester);
    await openInitialCheckIn(tester);
    await submitVisibleCheckIn(tester,
        name: 'Alex Patient', age: '31', symptoms: 'Sore throat');

    expect(find.text('My status'), findsOneWidget);
    await tester.tap(find.text('Check-in'));
    await tester.pumpAndSettle();

    final nameField =
        tester.widget<TextField>(find.widgetWithText(TextField, 'Full name'));
    final ageField =
        tester.widget<TextField>(find.widgetWithText(TextField, 'Age'));
    await tester.scrollUntilVisible(find.text('Main symptoms'), 500,
        scrollable: find.byType(Scrollable).last);
    final symptomsField = tester
        .widget<TextField>(find.widgetWithText(TextField, 'Main symptoms'));
    expect(nameField.controller?.text, isEmpty);
    expect(ageField.controller?.text, isEmpty);
    expect(symptomsField.controller?.text, isEmpty);
    expect(find.text('Pain severity: 5 out of 10'), findsOneWidget);
  });

  testWidgets('second successful check-in overwrites current local patient',
      (tester) async {
    await pumpApp(tester);
    await openInitialCheckIn(tester);
    await submitVisibleCheckIn(tester,
        name: 'Alex Patient', age: '31', symptoms: 'Sore throat');

    await tester.tap(find.text('Check-in'));
    await tester.pumpAndSettle();
    await submitVisibleCheckIn(tester,
        name: 'Blair Patient', age: '45', symptoms: 'Ankle pain');

    expect(find.text('My status'), findsOneWidget);
    await tester.tap(find.text('My info'));
    await tester.pumpAndSettle();
    expect(find.text('Blair Patient'), findsOneWidget);
    expect(find.text('Alex Patient'), findsNothing);

    const storage = FlutterSecureStorage();
    expect(await storage.read(key: 'patient.localPatientId'), '2');
    expect(await storage.read(key: 'patient.accessToken'), 'token-2');
    expect(await storage.read(key: 'patient.localPatientId.1'), isNull);
  });

  testWidgets('failed second check-in keeps previous patient and form data',
      (tester) async {
    await pumpApp(tester);
    await openInitialCheckIn(tester);
    await submitVisibleCheckIn(tester,
        name: 'Alex Patient', age: '31', symptoms: 'Sore throat');

    api.failNextCheckIn = true;
    await tester.tap(find.text('Check-in'));
    await tester.pumpAndSettle();
    await submitVisibleCheckIn(tester,
        name: 'Blair Patient', age: '45', symptoms: 'Ankle pain');

    expect(find.textContaining('Check-in failed'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Blair Patient'), -500,
        scrollable: find.byType(Scrollable).last);
    expect(find.text('Blair Patient'), findsOneWidget);
    await tester.tap(find.text('My info'));
    await tester.pumpAndSettle();
    expect(find.text('Alex Patient'), findsOneWidget);
    expect(find.text('Blair Patient'), findsNothing);
  });

  testWidgets(
      'Feedback separates condition updates and app feedback with distinguishable payloads',
      (tester) async {
    await pumpApp(tester);
    await openInitialCheckIn(tester);
    await submitVisibleCheckIn(tester,
        name: 'Alex Patient', age: '31', symptoms: 'Sore throat');

    await tester.tap(find.text('Feedback'));
    await tester.pumpAndSettle();
    expect(find.text('Condition update'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Send update'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('App feedback'), 500,
        scrollable: find.byType(Scrollable).last);
    expect(find.text('App feedback'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Submit feedback'), 500,
        scrollable: find.byType(Scrollable).last);
    await tester.enterText(
        find.widgetWithText(TextField, 'Optional comment'), 'Easy to use');
    await tester.tap(find.text('Submit feedback'));
    await tester.pumpAndSettle();

    expect(api.updates[0]['message'], startsWith('[CONDITION_UPDATE]'));
    expect(api.updates[1]['message'], startsWith('[APP_FEEDBACK]'));
    expect(find.textContaining('[CONDITION_UPDATE]'), findsNothing);
    expect(find.textContaining('[APP_FEEDBACK]'), findsNothing);
  });

  testWidgets('automatic refresh still uses the current newest patient',
      (tester) async {
    await pumpApp(tester);
    await openInitialCheckIn(tester);
    await submitVisibleCheckIn(tester,
        name: 'Alex Patient', age: '31', symptoms: 'Sore throat');
    await tester.tap(find.text('Check-in'));
    await tester.pumpAndSettle();
    await submitVisibleCheckIn(tester,
        name: 'Blair Patient', age: '45', symptoms: 'Ankle pain');

    await tester.pump(const Duration(seconds: 9));
    expect(api.statusRequests, contains(2));
    expect(api.statusRequests, isNot(contains(1)));
  });

  testWidgets('patient status screen does not expose staff-only labels',
      (tester) async {
    const status = PatientStatus(
      localPatientId: 10,
      patientId: 100,
      status: 'Waiting',
      patientsAhead: 2,
      estimatedWaitRange: '20-30 minutes',
      queueNumber: 5,
      submittedInformation: {
        'name': 'Alex',
        'symptoms': 'Headache. Pain severity: 5/10.'
      },
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatusPage(
          patient: status,
          lastUpdate: DateTime(2026, 7, 6, 9, 30),
          refreshError: null,
          refreshing: false,
          onRefresh: () {},
        ),
      ),
    ));

    expect(find.text('Patients ahead'), findsOneWidget);
    expect(find.textContaining('Risk Score'), findsNothing);
    expect(find.textContaining('CTAS'), findsNothing);
    expect(find.textContaining('Reasoning'), findsNothing);
    expect(find.textContaining('Recommended action'), findsNothing);
    expect(find.textContaining('Staff notes'), findsNothing);
  });

  test('parseSubmittedSymptoms separates patient-visible details', () {
    final parsed = parseSubmittedSymptoms(
        'Chest pain. Pain severity: 7/10. Urgent warning signs: Dizziness.');

    expect(parsed.symptoms, 'Chest pain.');
    expect(parsed.painSeverity, '7/10');
    expect(parsed.warningSigns, 'Dizziness');
  });
}
