import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services.dart';
import '../../core/theme/app_theme.dart';
import '../../data/repositories.dart';

/// Enrols a worker on this handset, or switches to one already enrolled.
///
/// Phones are shared on these sites — one handset often serves a whole gang, or
/// belongs to a contractor rather than an individual — so "who is using this
/// right now" is an explicit choice rather than something baked into the
/// install. Getting this wrong would attribute one worker's training to
/// another, which is worse than having no record at all.
class EnrolmentScreen extends ConsumerStatefulWidget {
  const EnrolmentScreen({super.key});

  @override
  ConsumerState<EnrolmentScreen> createState() => _EnrolmentScreenState();
}

class _EnrolmentScreenState extends ConsumerState<EnrolmentScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _workerRef = TextEditingController();
  final _employerCode = TextEditingController();

  DateTime? _joinedAt;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _workerRef.dispose();
    _employerCode.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);

    try {
      final services = ref.read(servicesProvider);
      final worker = await services.workers.create(
        name: _name.text,
        workerRef: _workerRef.text,
        employerCode: _employerCode.text,
        joinedAt: _joinedAt,
      );
      await services.setActiveWorker(worker.id);

      ref.invalidate(activeWorkerProvider);
      ref.invalidate(workerListProvider);

      if (mounted) Navigator.of(context).pop(worker);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _select(WorkerRecord worker) async {
    final services = ref.read(servicesProvider);
    await services.setActiveWorker(worker.id);
    ref.invalidate(activeWorkerProvider);
    if (mounted) Navigator.of(context).pop(worker);
  }

  @override
  Widget build(BuildContext context) {
    final existing = ref.watch(workerListProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Who is training?')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            existing.maybeWhen(
              data: (workers) => workers.isEmpty
                  ? const SizedBox.shrink()
                  : _ExistingWorkers(workers: workers, onSelect: _select),
              orElse: () => const SizedBox.shrink(),
            ),
            const SizedBox(height: 8),
            Text(
              'Enrol a new worker',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 14),
            Form(
              key: _formKey,
              child: Column(
                children: [
                  TextFormField(
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Full name',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) => (value ?? '').trim().isEmpty
                        ? 'Enter the worker\'s name'
                        : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _workerRef,
                    decoration: const InputDecoration(
                      labelText: 'Token or roll number',
                      helperText: 'The number the employer already uses',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) => (value ?? '').trim().isEmpty
                        ? 'Enter the worker\'s token number'
                        : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _employerCode,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'Site or contractor code',
                      helperText: 'For example JH-DHN-0042',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) => (value ?? '').trim().isEmpty
                        ? 'Enter the site or contractor code'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  _JoinedDateField(
                    value: _joinedAt,
                    onChanged: (value) => setState(() => _joinedAt = value),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const _PrivacyNote(),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : const Text('Enrol and start'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExistingWorkers extends StatelessWidget {
  const _ExistingWorkers({required this.workers, required this.onSelect});

  final List<WorkerRecord> workers;
  final void Function(WorkerRecord) onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Already on this phone',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 10),
        for (final worker in workers)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: CircleAvatar(
                child: Text(
                  worker.name.characters.first.toUpperCase(),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              title: Text(worker.name),
              subtitle: Text('${worker.workerRef} · ${worker.employerCode}'),
              trailing: worker.isNewJoiner
                  ? const Tooltip(
                      message: 'Joined in the last 30 days',
                      child: Icon(
                        Icons.fiber_new,
                        color: AppTheme.cautionAmber,
                      ),
                    )
                  : const Icon(Icons.chevron_right),
              onTap: () => onSelect(worker),
            ),
          ),
        const Divider(height: 30),
      ],
    );
  }
}

/// Joining date, used to flag the under-30-days cohort.
///
/// Optional, and labelled as to why it is asked. The DGMS figures behind this
/// project single out workers with under 30 days of orientation, so this one
/// field is what lets the dashboard surface exactly that group.
class _JoinedDateField extends StatelessWidget {
  const _JoinedDateField({required this.value, required this.onChanged});

  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? now,
          firstDate: DateTime(now.year - 40),
          lastDate: now,
          helpText: 'When did this worker join the site?',
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: 'Date joined this site (optional)',
          helperText: 'Used to flag workers still in their first 30 days',
          border: OutlineInputBorder(),
        ),
        child: Text(
          value == null
              ? 'Not set'
              : '${value!.day}/${value!.month}/${value!.year}',
        ),
      ),
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.safeGreen.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.safeGreen.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lock_outline, size: 20, color: AppTheme.safeGreen),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'This stays on the phone until a supervisor syncs it. We do not '
              'ask for Aadhaar, a phone number, an address or a date of birth — '
              'only what a safety officer needs to confirm who trained.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
