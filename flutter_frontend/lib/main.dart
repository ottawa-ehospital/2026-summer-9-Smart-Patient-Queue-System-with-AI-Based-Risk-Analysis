import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const UrgentCareApp());
}

class UrgentCareApp extends StatelessWidget {
  const UrgentCareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'CareFlow',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF1F5F8B),
        scaffoldBackgroundColor: const Color(0xFFF6F7F9),
        cardTheme: CardThemeData(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Color(0xFFD9DEE8)),
          ),
        ),
      ),
      home: const DashboardPage(),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final apiBaseController = TextEditingController(text: 'http://127.0.0.1:8001');
  final patientIdController = TextEditingController();
  final nameController = TextEditingController(text: 'Testing Name 1');
  final ageController = TextEditingController(text: '35');
  final symptomsController = TextEditingController();
  final historyController = TextEditingController();
  final completedSearchController = TextEditingController();

  bool isLoading = false;
  String statusMessage = 'Ready.';
  Map<String, dynamic> summary = {};
  Map<String, dynamic> queues = {};
  List<dynamic> activePatients = [];
  List<dynamic> completedPatients = [];
  List<dynamic> alerts = [];
  final Set<String> dismissedAlertKeys = <String>{};

  static const queueOrder = [
    'Emergency Queue',
    'Normal Queue',
    'Non-Urgent Queue',
  ];

  @override
  void initState() {
    super.initState();
    refreshDashboard();
  }

  @override
  void dispose() {
    apiBaseController.dispose();
    patientIdController.dispose();
    nameController.dispose();
    ageController.dispose();
    symptomsController.dispose();
    historyController.dispose();
    completedSearchController.dispose();
    super.dispose();
  }

  String get apiBase => apiBaseController.text.trim().replaceAll(RegExp(r'/$'), '');

  Future<dynamic> apiRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final uri = Uri.parse('$apiBase$path');
    final headers = {'Content-Type': 'application/json'};
    late http.Response response;

    if (method == 'POST') {
      response = await http.post(uri, headers: headers, body: jsonEncode(body ?? {}));
    } else {
      response = await http.get(uri, headers: headers);
    }

    final decoded = response.body.isEmpty ? {} : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = decoded is Map ? decoded['detail'] ?? response.body : response.body;
      throw Exception(detail);
    }
    return decoded;
  }

  Future<void> refreshDashboard() async {
    setState(() {
      isLoading = true;
      statusMessage = 'Refreshing dashboard...';
    });

    try {
      final queueData = await apiRequest('GET', '/queues') as Map<String, dynamic>;
      final patientData = await apiRequest('GET', '/patients') as Map<String, dynamic>;
      final alertData = await apiRequest('GET', '/alerts') as Map<String, dynamic>;

      setState(() {
        summary = Map<String, dynamic>.from(queueData['summary'] ?? {});
        queues = Map<String, dynamic>.from(queueData['queues'] ?? {});
        activePatients = List<dynamic>.from(patientData['active'] ?? []);
        completedPatients = List<dynamic>.from(patientData['completed'] ?? []);
        alerts = List<dynamic>.from(alertData['alerts'] ?? []).reversed.toList();
        statusMessage = 'Dashboard refreshed.';
      });
    } catch (error) {
      setState(() {
        statusMessage = 'Cannot connect to backend. Please run uvicorn backend first.';
      });
    } finally {
      setState(() => isLoading = false);
    }
  }

  Future<void> submitCheckIn() async {
    final name = nameController.text.trim();
    final symptoms = symptomsController.text.trim();
    final age = int.tryParse(ageController.text.trim());

    if (name.isEmpty || symptoms.isEmpty || age == null) {
      setState(() => statusMessage = 'Please enter name, age, and symptoms.');
      return;
    }

    final payload = <String, dynamic>{
      'name': name,
      'age': age,
      'symptoms': symptoms,
      'medical_history': historyController.text.trim(),
    };

    final patientId = int.tryParse(patientIdController.text.trim());
    if (patientId != null && patientId > 0) {
      payload['patient_id'] = patientId;
    }

    setState(() {
      isLoading = true;
      statusMessage = 'Risk Analysis Agent is reviewing the case...';
    });

    try {
      final result = await apiRequest('POST', '/intake', body: payload) as Map<String, dynamic>;
      final patient = Map<String, dynamic>.from(result['patient'] ?? {});
      setState(() {
        statusMessage =
            'Added to ${patient['queue_name']} | ${patient['urgency_label']} | Risk Score ${patient['risk_score']}/10';
        symptomsController.clear();
        historyController.clear();
      });
      await refreshDashboard();
    } catch (error) {
      setState(() => statusMessage = 'Check-in failed: $error');
    } finally {
      setState(() => isLoading = false);
    }
  }

  Future<void> patientAction(int localId, String action) async {
    try {
      final result = await apiRequest('POST', '/patient/$localId/$action') as Map<String, dynamic>;
      setState(() => statusMessage = result['message']?.toString() ?? 'Action completed.');
      await refreshDashboard();
    } catch (error) {
      setState(() => statusMessage = 'Action failed: $error');
    }
  }

  Future<void> submitFeedback(
    Map<String, dynamic> patient,
    String rating,
    String queueFeedback,
    String conditionUpdate,
  ) async {
    final payload = {
      'patient_id': patient['patient_id'],
      'rating': rating,
      'message': queueFeedback,
      'condition_update': conditionUpdate,
      'ctas_level': patient['ctas_level'],
      'risk_score': patient['risk_score'],
    };

    try {
      final result = await apiRequest('POST', '/feedback', body: payload) as Map<String, dynamic>;
      final alert = Map<String, dynamic>.from(result['alert_agent'] ?? {});
      final alertRequired = alert['alert_required'] == true;
      setState(() {
        statusMessage = alertRequired
            ? 'Feedback Alert Agent: ${alert['severity']} alert. ${alert['recommended_staff_action']}'
            : alert['patient_message']?.toString() ?? 'Feedback saved.';
      });
      await refreshDashboard();
    } catch (error) {
      setState(() => statusMessage = 'Feedback failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          return buildDashboard();
        },
      ),
    );
  }

  Widget buildCheckInPanel() {
    return Container(
      color: Colors.white,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Patient Check-in',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Text(
              'Flutter frontend calling the FastAPI backend.',
              style: TextStyle(color: Color(0xFF667085)),
            ),
            const SizedBox(height: 18),
            buildTextField(
              patientIdController,
              'Patient ID',
              keyboardType: TextInputType.number,
              helperText: 'Returning patient? Enter patient ID for longitudinal analysis.',
            ),
            buildTextField(nameController, 'Patient Name'),
            buildTextField(ageController, 'Age', keyboardType: TextInputType.number),
            buildTextField(symptomsController, 'Symptom Description', maxLines: 4),
            buildTextField(historyController, 'Optional Medical History', maxLines: 4),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: isLoading ? null : submitCheckIn,
                child: const Text('Risk Analysis and Join Queue'),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Decision support only. This prototype does not replace doctors, diagnosis, or treatment.',
              style: TextStyle(color: Color(0xFF667085), height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildDashboard() {
    final isWideContent = MediaQuery.of(context).size.width >= 1050;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'CareFlow',
                      style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
              OutlinedButton(onPressed: refreshDashboard, child: const Text('Refresh')),
            ],
          ),
          const SizedBox(height: 20),
          buildStatusBox(),
          const SizedBox(height: 18),
          buildMetrics(),
          const SizedBox(height: 18),
          if (isWideContent)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 2, child: buildQueues()),
                const SizedBox(width: 18),
                Expanded(child: buildSidePanel()),
              ],
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                buildQueues(),
                const SizedBox(height: 18),
                buildSidePanel(),
              ],
            ),
          const SizedBox(height: 18),
          buildCompleted(),
        ],
      ),
    );
  }

  Widget buildStatusBox() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: statusMessage.startsWith('Cannot') || statusMessage.startsWith('Check-in failed')
            ? const Color(0xFFFDE2E2)
            : const Color(0xFFE8F1F8),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(statusMessage),
    );
  }

  Widget buildMetrics() {
    final items = [
      ('Total Patients', summary['total_patients'] ?? 0),
      ('Waiting', summary['waiting'] ?? 0),
      ('In Consultation', summary['in_consultation'] ?? 0),
      ('Completed', summary['completed'] ?? 0),
    ];

    return Row(
      children: items
          .map(
            (item) => Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.$1, style: const TextStyle(color: Color(0xFF667085))),
                      const SizedBox(height: 8),
                      Text(
                        item.$2.toString(),
                        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          )
          .toList(),
    );
  }

  Widget buildQueues() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Priority Queues', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        for (final queueName in queueOrder) buildQueueGroup(queueName),
      ],
    );
  }

  Widget buildQueueGroup(String queueName) {
    final patients = List<dynamic>.from(queues[queueName] ?? []);
    final hint = queueName == 'Emergency Queue'
        ? 'CTAS 1-2'
        : queueName == 'Normal Queue'
            ? 'CTAS 3'
            : 'CTAS 4-5';

    return Card(
      child: ExpansionTile(
        initiallyExpanded: true,
        title: Text('$queueName ($hint)'),
        subtitle: Text('${patients.length} patient(s)'),
        children: patients.isEmpty
            ? [const ListTile(title: Text('No patients in this queue.'))]
            : patients
                .map((patient) => buildPatientCard(Map<String, dynamic>.from(patient)))
                .toList(),
      ),
    );
  }

  Widget buildPatientCard(Map<String, dynamic> patient) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    patient['name']?.toString() ?? 'Unnamed Patient',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  buildBadge(
                    patient['urgency_label']?.toString() ?? 'CTAS',
                    ctasColor(patient['ctas_level']),
                  ),
                  buildBadge('Risk Score: ${patient['risk_score']}/10', const Color(0xFFEFF2F7)),
                  buildBadge(patient['status']?.toString() ?? 'Unknown', const Color(0xFFEFF2F7)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Patient ID: ${patient['patient_id']} | Age: ${patient['age']} | Waiting: ${patient['waiting_minutes'] ?? 0} min',
                style: const TextStyle(color: Color(0xFF667085)),
              ),
              const SizedBox(height: 12),
              Text(patient['clinical_summary']?.toString() ?? 'No summary available.'),
              const SizedBox(height: 8),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Clinical decision support report'),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(patient['reasoning'] ?? 'No report available.'),
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Recommended action: ${patient['recommended_action'] ?? 'No action provided.'}',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: () => patientAction(patient['id'] as int, 'start'),
                    child: const Text('Start Consultation'),
                  ),
                  FilledButton(
                    onPressed: () => patientAction(patient['id'] as int, 'complete'),
                    child: const Text('Mark as Completed'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildSidePanel() {
    final visibleAlerts = alerts
        .map((item) => Map<String, dynamic>.from(item))
        .where((alert) => !dismissedAlertKeys.contains(alertKey(alert)))
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Feedback Alerts', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        if (visibleAlerts.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No active feedback alerts.'),
            ),
          )
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final alert in visibleAlerts) buildAlertCard(alert),
                    ],
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 18),
        const Text('Urgency Distribution', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        buildUrgencyDistribution(),
      ],
    );
  }

  String alertKey(Map<String, dynamic> alert) {
    return [
      alert['feedback_id'],
      alert['record_id'],
      alert['patient_id'],
      alert['created_time'],
      alert['alert_reason'],
      alert['condition_update'],
    ].where((part) => part != null && part.toString().isNotEmpty).join('|');
  }

  Widget buildAlertCard(Map<String, dynamic> alert) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFFFFFBEB),
          border: Border.all(color: const Color(0xFFF4D38D)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      '${alert['severity']?.toString().toUpperCase()} Alert - Patient ID ${alert['patient_id']}',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Dismiss alert',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      setState(() => dismissedAlertKeys.add(alertKey(alert)));
                    },
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(alert['alert_reason']?.toString() ?? 'No alert reason provided.'),
              const SizedBox(height: 8),
              Text(
                alert['recommended_staff_action']?.toString() ?? 'Staff review recommended.',
                style: const TextStyle(color: Color(0xFF1F5F8B)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildUrgencyDistribution() {
    final allPatients = [...activePatients, ...completedPatients];
    final counts = {
      for (var level = 1; level <= 5; level++)
        level: allPatients.where((patient) => patient['ctas_level'] == level).length,
    };
    final maxCount = counts.values.fold<int>(1, (max, value) => value > max ? value : max);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: counts.entries.map((entry) {
            final widthFactor = entry.value / maxCount;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [Text('CTAS ${entry.key}'), Text(entry.value.toString())],
                  ),
                  const SizedBox(height: 5),
                  LinearProgressIndicator(value: widthFactor == 0 ? 0.02 : widthFactor),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget buildCompleted() {
    final query = completedSearchController.text.trim().toLowerCase();
    final filteredPatients = completedPatients.where((item) {
      final patient = Map<String, dynamic>.from(item);
      final searchable = [
        patient['name'],
        patient['patient_id'],
        patient['record_id'],
        patient['urgency_label'],
        patient['status'],
      ].where((part) => part != null).join(' ').toLowerCase();
      return query.isEmpty || searchable.contains(query);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          child: ExpansionTile(
            initiallyExpanded: false,
            title: const Text(
              'Completed / Discharged History',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            subtitle: Text('${completedPatients.length} completed patient(s)'),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              TextField(
                controller: completedSearchController,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Search by name, patient ID, record ID, or urgency',
                  prefixIcon: const Icon(Icons.search),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 12),
              if (completedPatients.isEmpty)
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('No completed patients yet.'),
                )
              else if (filteredPatients.isEmpty)
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('No completed patients match this search.'),
                )
              else
                for (final item in filteredPatients)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        border: Border.all(color: const Color(0xFFD9DEE8)),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: ListTile(
                        title: Text(item['name']?.toString() ?? 'Unnamed Patient'),
                        subtitle: Text(
                          'Patient ID: ${item['patient_id']} | Record ID: ${item['record_id'] ?? 'N/A'} | ${item['urgency_label']}',
                        ),
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }

  Widget buildTextField(
    TextEditingController controller,
    String label, {
    int maxLines = 1,
    TextInputType? keyboardType,
    String? helperText,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          helperText: helperText,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }

  Widget buildBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(999)),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }

  Color ctasColor(dynamic level) {
    switch (level) {
      case 1:
        return const Color(0xFFFDE2E2);
      case 2:
        return const Color(0xFFFFE8D5);
      case 3:
        return const Color(0xFFFEF3C7);
      case 4:
        return const Color(0xFFDCFCE7);
      default:
        return const Color(0xFFE2E8F0);
    }
  }

  void showFeedbackDialog(Map<String, dynamic> patient) {
    String rating = 'Reasonable';
    final queueFeedbackController = TextEditingController();
    final conditionController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Feedback Chatbot'),
              content: SizedBox(
                width: 480,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Patient ID ${patient['patient_id']}'),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: rating,
                      decoration: const InputDecoration(labelText: 'Rating'),
                      items: const [
                        DropdownMenuItem(value: 'Reasonable', child: Text('Reasonable')),
                        DropdownMenuItem(value: 'Too high', child: Text('Too high')),
                        DropdownMenuItem(value: 'Too low', child: Text('Too low')),
                        DropdownMenuItem(value: 'Unsure', child: Text('Unsure')),
                      ],
                      onChanged: (value) {
                        if (value != null) setDialogState(() => rating = value);
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: queueFeedbackController,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Queue / urgency feedback',
                        hintText: 'For example: Was the queue priority or urgency level reasonable?',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: conditionController,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Current condition update (optional)',
                        hintText: 'For example: symptoms are worse, new chest pain, dizziness, breathing difficulty...',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                FilledButton(
                  onPressed: () {
                    Navigator.pop(context);
                    submitFeedback(
                      patient,
                      rating,
                      queueFeedbackController.text.trim(),
                      conditionController.text.trim(),
                    );
                  },
                  child: const Text('Submit Feedback'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
