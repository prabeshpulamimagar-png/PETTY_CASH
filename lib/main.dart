import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

const String appsScriptUrl =
    "https://script.google.com/macros/s/AKfycbyS4HAN9pc1wCg5VvIs6Jr3clmu7jOM1INtIxBBwvRbkQGs-ScRrXn87DV9pGvAZjQd/exec";

const String offlineQueueKey = "petty_cash_offline_queue";

const String staffCachePrefix = "petty_cash_staff_cache_";
const String staffCacheTimePrefix = "petty_cash_staff_cache_time_";

const int localCacheRefreshSeconds = 120;

void main() {
  runApp(const PettyCashApp());
}

class PettyCashApp extends StatelessWidget {
  const PettyCashApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: "PETTY CASH",
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
      ),
      home: const PettyCashScreen(),
    );
  }
}

enum SaveResult {
  saved,
  duplicate,
  rejected,
  offline,
  unknown,
}

class PettyCashScreen extends StatefulWidget {
  const PettyCashScreen({super.key});

  @override
  State<PettyCashScreen> createState() => _PettyCashScreenState();
}

class _PettyCashScreenState extends State<PettyCashScreen> {
  final TextEditingController empCodeController = TextEditingController();
  final TextEditingController billNoController = TextEditingController();
  final TextEditingController amountController = TextEditingController();
  final TextEditingController remarksController = TextEditingController();

  StreamSubscription<List<ConnectivityResult>>? connectivitySubscription;

  Timer? syncTimer;

  bool isSearching = false;
  bool isSaving = false;
  bool isSyncing = false;

  String staffName = "";
  String company = "";
  String mobile = "";

  double totalAdvance = 0;
  double totalBill = 0;
  double remainingBalance = 0;

  String transactionType = "ADVANCE";

  String? pendingSyncId;

  String? activeSearchEmpCode;
  Future<void>? activeSearchRequest;

  @override
  void initState() {
    super.initState();

    connectivitySubscription =
        Connectivity().onConnectivityChanged.listen((results) {
      if (_hasInternet(results)) {
        _syncOfflineQueue();
      }
    });

    syncTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) {
        _syncOfflineQueue();
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncOfflineQueue();
    });
  }

  @override
  void dispose() {
    connectivitySubscription?.cancel();
    syncTimer?.cancel();

    empCodeController.dispose();
    billNoController.dispose();
    amountController.dispose();
    remarksController.dispose();

    super.dispose();
  }

  bool _hasInternet(List<ConnectivityResult> results) {
    return results.contains(ConnectivityResult.mobile) ||
        results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet) ||
        results.contains(ConnectivityResult.vpn);
  }

  Future<bool> hasInternet() async {
    try {
      final results = await Connectivity().checkConnectivity();
      return _hasInternet(results);
    } catch (_) {
      return false;
    }
  }

  double toDouble(dynamic value) {
    if (value == null) return 0;

    if (value is num) {
      return value.toDouble();
    }

    return double.tryParse(
          value.toString().replaceAll(",", "").trim(),
        ) ??
        0;
  }

  String createSyncId() {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final random = DateTime.now().microsecondsSinceEpoch.remainder(1000000);

    return "TX_${now}_$random";
  }

  Map<String, dynamic>? _safeMapDecode(String source) {
    try {
      final decoded = jsonDecode(source);

      if (decoded is Map<String, dynamic>) {
        return decoded;
      }

      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}

    return null;
  }

  Future<http.Response> getWithRetry(
    Uri uri, {
    int timeoutSeconds = 10,
  }) async {
    return await http.get(
      uri,
      headers: const {
        "Accept": "application/json",
      },
    ).timeout(
      Duration(seconds: timeoutSeconds),
    );
  }

  Future<http.Response> postRequest(
    Uri uri,
    String body, {
    int timeoutSeconds = 20,
  }) async {
    return await http
        .post(
          uri,
          headers: const {
            "Content-Type": "application/json",
            "Accept": "application/json",
          },
          body: body,
        )
        .timeout(
          Duration(seconds: timeoutSeconds),
        );
  }

  String _cacheKey(String empCode) {
    return "$staffCachePrefix${empCode.toUpperCase()}";
  }

  String _cacheTimeKey(String empCode) {
    return "$staffCacheTimePrefix${empCode.toUpperCase()}";
  }

  Future<void> saveStaffCache(
    String empCode,
    Map<String, dynamic> driver,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      await prefs.setString(
        _cacheKey(empCode),
        jsonEncode(driver),
      );

      await prefs.setInt(
        _cacheTimeKey(empCode),
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> getStaffCache(
    String empCode,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final raw = prefs.getString(
        _cacheKey(empCode),
      );

      if (raw == null || raw.isEmpty) {
        return null;
      }

      final decoded = jsonDecode(raw);

      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}

    return null;
  }

  Future<bool> isStaffCacheFresh(
    String empCode,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final savedTime = prefs.getInt(
        _cacheTimeKey(empCode),
      );

      if (savedTime == null) {
        return false;
      }

      final age = DateTime.now().millisecondsSinceEpoch - savedTime;

      return age <
          const Duration(
            seconds: localCacheRefreshSeconds,
          ).inMilliseconds;
    } catch (_) {
      return false;
    }
  }

  void applyDriverData(
    Map<String, dynamic> driver,
  ) {
    if (!mounted) return;

    setState(() {
      staffName = driver["driverName"]?.toString() ?? "";

      company = driver["company"]?.toString() ?? "";

      mobile = driver["mobile"]?.toString() ?? "";

      totalAdvance = toDouble(driver["totalAdvance"]);

      totalBill = toDouble(driver["totalBill"]);

      remainingBalance = toDouble(driver["remainingBalance"]);
    });
  }

  Future<void> searchDriver() async {
    final empCode = empCodeController.text.trim().toUpperCase();

    if (empCode.isEmpty) {
      showMessage("Please enter Emp Code");
      return;
    }

    if (activeSearchEmpCode == empCode && activeSearchRequest != null) {
      await activeSearchRequest;
      return;
    }

    FocusScope.of(context).unfocus();

    final request = _performSearch(empCode);

    activeSearchEmpCode = empCode;
    activeSearchRequest = request;

    try {
      await request;
    } finally {
      if (activeSearchEmpCode == empCode) {
        activeSearchEmpCode = null;
        activeSearchRequest = null;
      }
    }
  }

  Future<void> _performSearch(
    String empCode,
  ) async {
    final cachedDriver = await getStaffCache(empCode);

    final cacheFresh = await isStaffCacheFresh(empCode);

    if (cachedDriver != null) {
      applyDriverData(cachedDriver);

      if (mounted) {
        setState(() {
          isSearching = true;
        });
      }

      if (cacheFresh) {
        if (mounted) {
          setState(() {
            isSearching = false;
          });
        }

        _backgroundRefresh(empCode);
        return;
      }
    } else {
      if (mounted) {
        setState(() {
          isSearching = true;

          staffName = "";
          company = "";
          mobile = "";

          totalAdvance = 0;
          totalBill = 0;
          remainingBalance = 0;

          billNoController.clear();
          amountController.clear();
          remarksController.clear();

          transactionType = "ADVANCE";

          pendingSyncId = null;
        });
      }
    }

    await _refreshFromGoogle(
      empCode,
      clearOnNotFound: cachedDriver == null,
    );
  }

  Future<void> _backgroundRefresh(
    String empCode,
  ) async {
    try {
      final internet = await hasInternet();

      if (!internet) {
        return;
      }

      await _refreshFromGoogle(
        empCode,
        clearOnNotFound: false,
        background: true,
      );
    } catch (_) {}
  }

  Future<void> _refreshFromGoogle(
    String empCode, {
    bool clearOnNotFound = true,
    bool background = false,
  }) async {
    try {
      final uri = Uri.parse(
        "$appsScriptUrl?action=getDriver"
        "&empCode=${Uri.encodeComponent(empCode)}",
      );

      final response = await getWithRetry(
        uri,
        timeoutSeconds: 10,
      );

      if (response.statusCode != 200) {
        throw Exception(
          "Server error ${response.statusCode}",
        );
      }

      final body = _safeMapDecode(response.body);

      if (body == null) {
        throw Exception(
          "Invalid JSON response from server",
        );
      }

      if (body["success"] == true) {
        final driverRaw = body["driver"];

        final driver = driverRaw is Map
            ? Map<String, dynamic>.from(driverRaw)
            : <String, dynamic>{};

        await saveStaffCache(
          empCode,
          driver,
        );

        if (!mounted) return;

        if (empCodeController.text.trim().toUpperCase() == empCode) {
          applyDriverData(driver);
        }
      } else {
        if (clearOnNotFound && mounted) {
          setState(() {
            staffName = "";
            company = "";
            mobile = "";

            totalAdvance = 0;
            totalBill = 0;
            remainingBalance = 0;
          });
        }

        if (!background && mounted) {
          showMessage(
            body["message"]?.toString() ?? "Staff not found",
          );
        }
      }
    } on TimeoutException {
      if (!background && mounted) {
        showMessage(
          "Google Sheet connection is slow. Please try again.",
        );
      }
    } catch (_) {
      if (!background && mounted) {
        final cache = await getStaffCache(empCode);

        if (cache == null) {
          showMessage(
            "Unable to connect to Google Sheet.",
          );
        } else {
          showMessage(
            "Showing saved staff data.",
          );
        }
      }
    } finally {
      if (!background && mounted) {
        setState(() {
          isSearching = false;
        });
      }
    }
  }

  Future<void> openScanner() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => const QRScannerPage(),
      ),
    );

    if (result != null && result.trim().isNotEmpty) {
      empCodeController.text = result.trim().toUpperCase();

      await searchDriver();
    }
  }

  Future<void> sendWhatsAppMessage(
    String type,
    double amount,
  ) async {
    if (mobile.trim().isEmpty || mobile.trim() == "-") {
      return;
    }

    String cleanPhone = mobile.replaceAll(RegExp(r'\D'), '');

    if (cleanPhone.startsWith('0')) {
      cleanPhone = cleanPhone.substring(1);
    }

    if (!cleanPhone.startsWith('971')) {
      cleanPhone = '971$cleanPhone';
    }

    double updatedBalance = remainingBalance;

    if (type == "ADVANCE") {
      updatedBalance += amount;
    } else if (type == "BILL") {
      updatedBalance -= amount;
    }

    final empCode = empCodeController.text.trim();

    final billNo = billNoController.text.trim();

    String message =
        "Hello $staffName (Emp Code: $empCode), your $type of ${formatMoney(amount)} has been recorded.";

    if (type == "BILL" && billNo.isNotEmpty) {
      message += " Bill No: $billNo.";
    }

    message += " Remaining Balance: ${formatMoney(updatedBalance)}";

    final Uri whatsappUri = Uri.parse(
      "intent://send?phone=$cleanPhone&text=${Uri.encodeComponent(message)}#Intent;package=com.whatsapp;scheme=whatsapp;end;",
    );

    try {
      if (await canLaunchUrl(
        whatsappUri,
      )) {
        await launchUrl(
          whatsappUri,
          mode: LaunchMode.externalApplication,
        );
      } else {
        final Uri fallbackUri = Uri.parse(
          "https://wa.me/$cleanPhone?text=${Uri.encodeComponent(message)}",
        );

        await launchUrl(
          fallbackUri,
          mode: LaunchMode.externalApplication,
        );
      }
    } catch (_) {
      showMessage(
        "Error opening WhatsApp",
      );
    }
  }

  Future<void> saveTransaction() async {
    if (isSaving) return;

    final empCode = empCodeController.text.trim();

    final amountText = amountController.text.trim();

    final billNo = billNoController.text.trim();

    final remarks = remarksController.text.trim();

    if (empCode.isEmpty) {
      showMessage(
        "Please enter Emp Code",
      );
      return;
    }

    if (staffName.isEmpty) {
      showMessage(
        "Please search staff first",
      );
      return;
    }

    if (transactionType == "BILL" && billNo.isEmpty) {
      showMessage(
        "Bill No is required",
      );
      return;
    }

    final amount = double.tryParse(
      amountText.replaceAll(",", ""),
    );

    if (amount == null || amount <= 0) {
      showMessage(
        "Please enter valid amount",
      );
      return;
    }

    setState(() {
      isSaving = true;
    });

    final syncId = pendingSyncId ?? createSyncId();

    pendingSyncId = syncId;

    final transaction = <String, dynamic>{
      "action": "addTransaction",
      "empCode": empCode,
      "type": transactionType,
      "billNo": transactionType == "BILL" ? billNo : "",
      "amount": amount,
      "remarks": remarks,
      "syncId": syncId,
    };

    try {
      final internet = await hasInternet();

      if (!internet) {
        await saveOfflineTransaction(
          transaction,
        );

        if (mounted) {
          showMessage(
            "OFFLINE SAVED",
          );

          clearTransactionFields();
        }

        return;
      }

      final result = await sendTransactionToGoogle(
        transaction,
      );

      if (!mounted) return;

      if (result == SaveResult.saved) {
        showMessage(
          "SAVED IN GOOGLE SHEET",
        );

        await sendWhatsAppMessage(
          transactionType,
          amount,
        );

        pendingSyncId = null;

        clearTransactionFields();

        await removeStaffCache(
          empCode,
        );

        await searchDriver();
      } else if (result == SaveResult.duplicate) {
        showMessage(
          "Already saved in Google Sheet",
        );

        pendingSyncId = null;

        clearTransactionFields();

        await removeStaffCache(
          empCode,
        );

        await searchDriver();
      } else if (result == SaveResult.offline) {
        await saveOfflineTransaction(
          transaction,
        );

        showMessage(
          "OFFLINE SAVED",
        );

        clearTransactionFields();
      } else {
        showMessage(
          "Unable to save transaction",
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          isSaving = false;
        });
      }
    }
  }

  // ==========================================================
  // FIXED SAVE FUNCTION
  // ==========================================================

  Future<SaveResult> sendTransactionToGoogle(
    Map<String, dynamic> transaction,
  ) async {
    final syncId = transaction["syncId"]?.toString() ?? "";

    try {
      final response = await postRequest(
        Uri.parse(appsScriptUrl),
        jsonEncode(transaction),
        timeoutSeconds: 20,
      );

      final body = _safeMapDecode(response.body);

      // ------------------------------------------------------
      // 1. NORMAL JSON SUCCESS
      // ------------------------------------------------------

      if (body != null) {
        if (body["success"] == true ||
            body["saved"] == true ||
            body["alreadySaved"] == true) {
          return SaveResult.saved;
        }

        if (body["duplicate"] == true) {
          return SaveResult.duplicate;
        }
      }

      // ------------------------------------------------------
      // 2. RESPONSE NOT READABLE
      //
      // Google Apps Script can sometimes return a redirect/
      // non-standard response even though POST was successful.
      //
      // Therefore verify the exact Sync ID from the Sheet.
      // ------------------------------------------------------

      final found = await checkSyncIdOnServer(
        syncId,
      );

      if (found) {
        return SaveResult.saved;
      }

      // ------------------------------------------------------
      // 3. SERVER REJECTED
      // ------------------------------------------------------

      if (body != null && body["success"] == false) {
        return SaveResult.rejected;
      }

      // ------------------------------------------------------
      // 4. NON-200
      // ------------------------------------------------------

      if (response.statusCode != 200) {
        return SaveResult.unknown;
      }

      return SaveResult.unknown;
    } on TimeoutException {
      // POST may already have reached Google.
      final found = await checkSyncIdOnServer(
        syncId,
      );

      if (found) {
        return SaveResult.saved;
      }

      return SaveResult.offline;
    } catch (_) {
      // Same protection for connection/
      // redirect/JSON errors.
      final found = await checkSyncIdOnServer(
        syncId,
      );

      if (found) {
        return SaveResult.saved;
      }

      return SaveResult.offline;
    }
  }

  // ==========================================================
  // FIXED SYNC ID VERIFICATION
  // ==========================================================

  Future<bool> checkSyncIdOnServer(
    String syncId,
  ) async {
    if (syncId.trim().isEmpty) {
      return false;
    }

    try {
      final uri = Uri.parse(
        "$appsScriptUrl?action=checkTransaction"
        "&syncId=${Uri.encodeComponent(syncId.trim())}",
      );

      final response = await http.get(
        uri,
        headers: const {
          "Accept": "application/json",
        },
      ).timeout(
        const Duration(
          seconds: 10,
        ),
      );

      final body = _safeMapDecode(response.body);

      if (body == null) {
        return false;
      }

      // ------------------------------------------------------
      // Accept all common success formats.
      // ------------------------------------------------------

      if (body["found"] == true) {
        return true;
      }

      if (body["saved"] == true) {
        return true;
      }

      if (body["alreadySaved"] == true) {
        return true;
      }

      if (body["duplicate"] == true) {
        return true;
      }

      if (body["success"] == true && body["transaction"] != null) {
        return true;
      }

      // Some Code.gs versions return:
      // success:true + message
      if (body["success"] == true && body["message"] != null) {
        final message = body["message"].toString().toLowerCase();

        if (message.contains("saved") ||
            message.contains("already") ||
            message.contains("found") ||
            message.contains("duplicate")) {
          return true;
        }
      }

      return false;
    } catch (_) {
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> getOfflineQueue() async {
    final prefs = await SharedPreferences.getInstance();

    final list = prefs.getStringList(
          offlineQueueKey,
        ) ??
        [];

    final result = <Map<String, dynamic>>[];

    for (final item in list) {
      try {
        final decoded = jsonDecode(item);

        if (decoded is Map) {
          result.add(
            Map<String, dynamic>.from(
              decoded,
            ),
          );
        }
      } catch (_) {}
    }

    return result;
  }

  Future<void> saveOfflineTransaction(
    Map<String, dynamic> transaction,
  ) async {
    final prefs = await SharedPreferences.getInstance();

    final list = prefs.getStringList(
          offlineQueueKey,
        ) ??
        [];

    final syncId = transaction["syncId"]?.toString() ?? "";

    if (syncId.isEmpty) return;

    bool exists = false;

    for (final item in list) {
      try {
        final decoded = jsonDecode(item);

        if (decoded is Map && decoded["syncId"]?.toString() == syncId) {
          exists = true;
          break;
        }
      } catch (_) {}
    }

    if (!exists) {
      list.add(
        jsonEncode(transaction),
      );

      await prefs.setStringList(
        offlineQueueKey,
        list,
      );
    }
  }

  Future<void> _syncOfflineQueue() async {
    if (isSyncing) return;

    final internet = await hasInternet();

    if (!internet) return;

    final prefs = await SharedPreferences.getInstance();

    final list = prefs.getStringList(
          offlineQueueKey,
        ) ??
        [];

    if (list.isEmpty) return;

    isSyncing = true;

    try {
      final remaining = <String>[];

      for (final item in list) {
        try {
          final decoded = jsonDecode(item);

          if (decoded is! Map) {
            continue;
          }

          final transaction = Map<String, dynamic>.from(
            decoded,
          );

          final syncId = transaction["syncId"]?.toString() ?? "";

          if (syncId.isEmpty) {
            continue;
          }

          final alreadySaved = await checkSyncIdOnServer(
            syncId,
          );

          if (alreadySaved) {
            if (pendingSyncId == syncId) {
              pendingSyncId = null;
            }

            continue;
          }

          final result = await sendOfflineTransactionOnce(
            transaction,
          );

          if (result == SaveResult.saved || result == SaveResult.duplicate) {
            if (pendingSyncId == syncId) {
              pendingSyncId = null;
            }

            continue;
          }

          remaining.add(
            jsonEncode(transaction),
          );
        } catch (_) {
          remaining.add(item);
        }
      }

      await prefs.setStringList(
        offlineQueueKey,
        remaining,
      );
    } finally {
      isSyncing = false;
    }
  }

  Future<SaveResult> sendOfflineTransactionOnce(
    Map<String, dynamic> transaction,
  ) async {
    final syncId = transaction["syncId"]?.toString() ?? "";

    try {
      final response = await postRequest(
        Uri.parse(appsScriptUrl),
        jsonEncode(transaction),
        timeoutSeconds: 20,
      );

      final body = _safeMapDecode(response.body);

      if (body != null) {
        if (body["success"] == true ||
            body["saved"] == true ||
            body["alreadySaved"] == true) {
          return SaveResult.saved;
        }

        if (body["duplicate"] == true) {
          return SaveResult.duplicate;
        }
      }

      final found = await checkSyncIdOnServer(
        syncId,
      );

      return found ? SaveResult.saved : SaveResult.unknown;
    } on TimeoutException {
      final found = await checkSyncIdOnServer(
        syncId,
      );

      return found ? SaveResult.saved : SaveResult.unknown;
    } catch (_) {
      final found = await checkSyncIdOnServer(
        syncId,
      );

      return found ? SaveResult.saved : SaveResult.unknown;
    }
  }

  Future<void> removeStaffCache(
    String empCode,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      await prefs.remove(
        _cacheKey(empCode),
      );

      await prefs.remove(
        _cacheTimeKey(empCode),
      );
    } catch (_) {}
  }

  void clearTransactionFields() {
    if (!mounted) return;

    setState(() {
      transactionType = "ADVANCE";

      billNoController.clear();
      amountController.clear();
      remarksController.clear();
    });
  }

  Future<void> refreshDriver() async {
    if (empCodeController.text.trim().isEmpty) {
      return;
    }

    final empCode = empCodeController.text.trim().toUpperCase();

    await _refreshFromGoogle(
      empCode,
      clearOnNotFound: false,
    );
  }

  void showMessage(
    String message,
  ) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  String formatMoney(
    double value,
  ) {
    return NumberFormat(
      "#,##0.00",
    ).format(value);
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipOval(
              child: Image.asset(
                'assets/sk_new_logo.png',
                height: 36,
                width: 36,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(
              width: 8,
            ),
            const Text(
              "PETTY CASH",
              style: TextStyle(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        centerTitle: true,
      ),
      body: RefreshIndicator(
        onRefresh: refreshDriver,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: empCodeController,
                      textCapitalization: TextCapitalization.characters,
                      decoration: InputDecoration(
                        labelText: "Emp Code",
                        border: const OutlineInputBorder(),
                        suffixIcon: isSearching
                            ? const Padding(
                                padding: EdgeInsets.all(
                                  12,
                                ),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : null,
                      ),
                      onSubmitted: (_) {
                        searchDriver();
                      },
                    ),
                  ),
                  const SizedBox(
                    width: 8,
                  ),
                  SizedBox(
                    height: 56,
                    child: ElevatedButton(
                      onPressed: isSearching ? null : searchDriver,
                      child: const Text(
                        "SEARCH",
                      ),
                    ),
                  ),
                  const SizedBox(
                    width: 8,
                  ),
                  SizedBox(
                    height: 56,
                    width: 56,
                    child: ElevatedButton(
                      onPressed: isSearching ? null : openScanner,
                      child: const Icon(
                        Icons.qr_code_scanner,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(
                height: 16,
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(
                    16,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "STAFF INFORMATION",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(
                        height: 12,
                      ),
                      infoRow(
                        "Emp Code",
                        empCodeController.text,
                      ),
                      infoRow(
                        "Name",
                        staffName,
                      ),
                      infoRow(
                        "Company",
                        company,
                      ),
                      infoRow(
                        "Mobile No.",
                        mobile,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(
                height: 12,
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(
                    16,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "BALANCE",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(
                        height: 12,
                      ),
                      infoRow(
                        "Remaining Balance",
                        formatMoney(
                          remainingBalance,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(
                height: 12,
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(
                    16,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        "TRANSACTION",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(
                        height: 12,
                      ),
                      DropdownButtonFormField<String>(
                        value: transactionType,
                        decoration: const InputDecoration(
                          labelText: "Transaction Type",
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: "ADVANCE",
                            child: Text(
                              "ADVANCE",
                            ),
                          ),
                          DropdownMenuItem(
                            value: "BILL",
                            child: Text(
                              "BILL",
                            ),
                          ),
                        ],
                        onChanged: isSaving
                            ? null
                            : (value) {
                                if (value == null) {
                                  return;
                                }

                                setState(
                                  () {
                                    transactionType = value;

                                    if (value == "ADVANCE") {
                                      billNoController.clear();
                                    }
                                  },
                                );
                              },
                      ),
                      const SizedBox(
                        height: 12,
                      ),
                      if (transactionType == "BILL")
                        TextField(
                          controller: billNoController,
                          decoration: const InputDecoration(
                            labelText: "Bill No",
                            border: OutlineInputBorder(),
                          ),
                        ),
                      if (transactionType == "BILL")
                        const SizedBox(
                          height: 12,
                        ),
                      TextField(
                        controller: amountController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: "Amount",
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(
                        height: 12,
                      ),
                      TextField(
                        controller: remarksController,
                        maxLines: 2,
                        decoration: const InputDecoration(
                          labelText: "Remarks",
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(
                        height: 16,
                      ),
                      SizedBox(
                        height: 52,
                        child: ElevatedButton(
                          onPressed: isSaving ? null : saveTransaction,
                          child: isSaving
                              ? const SizedBox(
                                  height: 22,
                                  width: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text(
                                  "SAVE TRANSACTION",
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget infoRow(
    String title,
    String value,
  ) {
    return Padding(
      padding: const EdgeInsets.only(
        bottom: 8,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? "-" : value,
            ),
          ),
        ],
      ),
    );
  }
}

class QRScannerPage extends StatefulWidget {
  const QRScannerPage({
    super.key,
  });

  @override
  State<QRScannerPage> createState() => _QRScannerPageState();
}

class _QRScannerPageState extends State<QRScannerPage> {
  final MobileScannerController controller = MobileScannerController();

  bool alreadyScanned = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void onDetect(
    BarcodeCapture capture,
  ) {
    if (alreadyScanned) return;

    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;

      if (value != null && value.trim().isNotEmpty) {
        alreadyScanned = true;

        Navigator.pop(
          context,
          value.trim(),
        );

        break;
      }
    }
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("SCAN QR"),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.flash_on,
            ),
            onPressed: () {
              controller.toggleTorch();
            },
          ),
          IconButton(
            icon: const Icon(
              Icons.cameraswitch,
            ),
            onPressed: () {
              controller.switchCamera();
            },
          ),
        ],
      ),
      body: MobileScanner(
        controller: controller,
        onDetect: onDetect,
      ),
    );
  }
}
