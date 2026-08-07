/// One person's slice of a split bill: what they owe and whether they've paid.
///
/// The creator is a share too — their own portion — but it starts [paid]
/// because they already covered the whole bill; everyone else reimburses them.
class BillShare {
  final String name;

  /// The digits (or account code) the reimbursement is addressed to, and how a
  /// paid-update finds the right share. Empty only for a self share with no
  /// number, which is never collected.
  final String phone;
  final int cents;
  final bool paid;

  const BillShare({
    required this.name,
    required this.phone,
    required this.cents,
    this.paid = false,
  });

  BillShare copyWith({bool? paid}) => BillShare(
        name: name,
        phone: phone,
        cents: cents,
        paid: paid ?? this.paid,
      );

  Map<String, dynamic> toJson() =>
      {'name': name, 'phone': phone, 'cents': cents, 'paid': paid};

  factory BillShare.fromJson(Map<String, dynamic> j) => BillShare(
        name: (j['name'] as String?) ?? '',
        phone: (j['phone'] as String?) ?? '',
        cents: (j['cents'] as num?)?.toInt() ?? 0,
        paid: j['paid'] as bool? ?? false,
      );
}

/// A bill split shared into a conversation — the whole thing on the message,
/// like a poll's votes, so it is E2E encrypted and lives only on the devices
/// that took part. Never a server row.
class BillSplit {
  final String title;
  final int totalCents;
  final String currency;

  /// Who fronted the bill and is owed the reimbursements — the digits their
  /// shares are paid to.
  final String createdByPhone;
  final List<BillShare> shares;

  const BillSplit({
    required this.title,
    required this.totalCents,
    this.currency = 'cad',
    required this.createdByPhone,
    required this.shares,
  });

  static String _digits(String p) => p.replaceAll(RegExp(r'\D'), '');

  /// The share owed by [phone], or null if that person isn't on the bill.
  BillShare? shareFor(String phone) {
    final d = _digits(phone);
    for (final s in shares) {
      if (_digits(s.phone) == d) return s;
    }
    return null;
  }

  /// What everyone still owes the creator (unpaid, non-creator shares).
  int get outstandingCents {
    final owner = _digits(createdByPhone);
    return shares
        .where((s) => !s.paid && _digits(s.phone) != owner)
        .fold(0, (n, s) => n + s.cents);
  }

  /// What's been reimbursed so far (paid, non-creator shares).
  int get collectedCents {
    final owner = _digits(createdByPhone);
    return shares
        .where((s) => s.paid && _digits(s.phone) != owner)
        .fold(0, (n, s) => n + s.cents);
  }

  bool get settled => outstandingCents == 0;

  /// Returns a copy with [payerPhone]'s share marked paid.
  BillSplit markPaid(String payerPhone) {
    final d = _digits(payerPhone);
    return BillSplit(
      title: title,
      totalCents: totalCents,
      currency: currency,
      createdByPhone: createdByPhone,
      shares: [
        for (final s in shares)
          _digits(s.phone) == d ? s.copyWith(paid: true) : s,
      ],
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'totalCents': totalCents,
        'currency': currency,
        'by': createdByPhone,
        'shares': [for (final s in shares) s.toJson()],
      };

  factory BillSplit.fromJson(Map<String, dynamic> j) => BillSplit(
        title: (j['title'] as String?) ?? '',
        totalCents: (j['totalCents'] as num?)?.toInt() ?? 0,
        currency: (j['currency'] as String?) ?? 'cad',
        createdByPhone: (j['by'] as String?) ?? '',
        shares: [
          for (final s in (j['shares'] as List? ?? const []))
            BillShare.fromJson(Map<String, dynamic>.from(s as Map))
        ],
      );

  /// Splits [totalCents] as evenly as possible across [n] people, handing the
  /// leftover cents to the first few so the parts sum EXACTLY to the total —
  /// no penny lost or invented to a rounding error.
  static List<int> equalCents(int totalCents, int n) {
    if (n <= 0) return const [];
    final base = totalCents ~/ n;
    final remainder = totalCents % n;
    return [for (var i = 0; i < n; i++) base + (i < remainder ? 1 : 0)];
  }
}
