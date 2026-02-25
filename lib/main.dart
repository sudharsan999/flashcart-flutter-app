// ================= IMPORTS =================
import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ================= CONFIG =================
const Color brandColor = Color(0xFF246A25);
const Color accentYellow = Color(0xFFF7E169);

const double freeDeliveryThreshold = 300.0;
const double deliveryFee = 30.0;

// ================= MAIN =================
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await dotenv.load(fileName: ".env");
  } catch (_) {}

  final supabaseUrl = const String.fromEnvironment('SUPABASE_URL').isNotEmpty
      ? const String.fromEnvironment('SUPABASE_URL')
      : dotenv.env['SUPABASE_URL'];

  final supabaseKey =
      const String.fromEnvironment('SUPABASE_ANON_KEY').isNotEmpty
          ? const String.fromEnvironment('SUPABASE_ANON_KEY')
          : dotenv.env['SUPABASE_ANON_KEY'];

  if (supabaseUrl == null ||
      supabaseKey == null ||
      supabaseUrl.isEmpty ||
      supabaseKey.isEmpty) {
    runApp(const _FatalErrorApp("Supabase ENV missing"));
    return;
  }

  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseKey);

  runApp(const FlashCartApp());
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();

    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const RootNavigation()),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [accentYellow, brandColor],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // LOGO
              Image.asset(
                'assets/logo.png',
                height: 140,
              ),

              const SizedBox(height: 20),

              // APP NAME / TAGLINE
              const Text(
                "FlashCart",
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  letterSpacing: 1,
                ),
              ),

              const SizedBox(height: 8),

              const Text(
                "Groceries in a Flash ⚡",
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white70,
                ),
              ),

              const SizedBox(height: 30),

              // LOADING INDICATOR
              const CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2.5,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ================= ERROR FALLBACK =================
class _FatalErrorApp extends StatelessWidget {
  final String message;
  const _FatalErrorApp(this.message);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(body: Center(child: Text(message))),
    );
  }
}

// ================= APP =================
class FlashCartApp extends StatelessWidget {
  const FlashCartApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, fontFamily: 'sans-serif'),
      home: const SplashScreen(),
    );
  }
}

// ================= ROOT NAVIGATION =================
class RootNavigation extends StatefulWidget {
  const RootNavigation({super.key});

  @override
  State<RootNavigation> createState() => _RootNavigationState();
}

class _RootNavigationState extends State<RootNavigation> {
  bool isAdmin = false;
  final emailCtrl = TextEditingController();
  final passCtrl = TextEditingController();

  void _openAdmin() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Manager Login"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: emailCtrl,
              decoration: const InputDecoration(labelText: "Email"),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: passCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: "Password"),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () async {
              try {
                final res =
                    await Supabase.instance.client.auth.signInWithPassword(
                  email: emailCtrl.text.trim(),
                  password: passCtrl.text.trim(),
                );

                if (res.session != null) {
                  emailCtrl.clear();
                  passCtrl.clear();
                  Navigator.pop(context);
                  setState(() => isAdmin = true);
                }
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Login failed")),
                );
              }
            },
            child: const Text("Login"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return isAdmin
        ? AdminDashboard(onBack: () => setState(() => isAdmin = false))
        : CustomerHome(onAdmin: _openAdmin);
  }
}

// ================= CUSTOMER HOME =================
class CustomerHome extends StatefulWidget {
  final VoidCallback onAdmin;
  const CustomerHome({super.key, required this.onAdmin});

  @override
  State<CustomerHome> createState() => _CustomerHomeState();
}

class _CustomerHomeState extends State<CustomerHome> {
  final supabase = Supabase.instance.client;

  String? activeCategory;
  String searchQuery = "";
  bool isStoreOpen = true;

  final cart = <String, Map<String, dynamic>>{};
  final nameCtrl = TextEditingController();
  final phoneCtrl = TextEditingController();
  final addrCtrl = TextEditingController();

  Timer? _debounce;
  List<Map<String, dynamic>>? cachedCategories;

  final serviceableAreas = [
    'ranipet',
    'lalapet',
    'BHEL',
    'arcot',
    'bharathi nagar',
    'bharati nagar',
    'thiruvalam',
    'tiruvlam',
    'sipcot',
    'bhel',
  ];

  @override
  void initState() {
    super.initState();
    _initStoreStatus();
  }

  void _initStoreStatus() async {
    try {
      final data = await supabase
          .from('store_settings')
          .select()
          .eq('id', 1)
          .maybeSingle();

      if (data != null) {
        setState(() => isStoreOpen = data['is_open'] ?? true);
      }
    } catch (e) {
      print("Store status error: $e");
    }
  }

  bool _serviceable(String addr) {
    final cleanAddr = addr.toLowerCase().trim();
    // Checks if any of your keywords exist within the typed address
    return serviceableAreas
        .any((area) => cleanAddr.contains(area.toLowerCase()));
  }

  Map<String, dynamic> _price(Map p) {
    final mrp = (p['price'] as num?)?.toDouble() ?? 0;
    final sp = (p['selling_price'] as num?)?.toDouble() ?? 0;
    final has = sp > 0 && sp < mrp;
    return {'final': has ? sp : mrp, 'mrp': mrp, 'sp': sp, 'has': has};
  }

  Future<List<Map<String, dynamic>>> _categories() async {
    cachedCategories ??= List<Map<String, dynamic>>.from(
      await supabase.from('categories').select().order('display_order'),
    );
    return cachedCategories!;
  }

  Future<List<Map<String, dynamic>>> _products() async {
    final res = searchQuery.isNotEmpty
        ? await supabase
            .from('products')
            .select()
            .ilike('name', '%$searchQuery%')
        : await supabase
            .from('products')
            .select()
            .eq('category', activeCategory ?? '');
    return List<Map<String, dynamic>>.from(res);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;

        if (activeCategory != null || searchQuery.isNotEmpty) {
          setState(() {
            activeCategory = null;
            searchQuery = "";
          });
        } else {
          Navigator.of(context).maybePop();
        }
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: _glassAppBar(),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [accentYellow, brandColor],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: !isStoreOpen
              ? _closedView()
              : Column(
                  children: [
                    const SizedBox(height: kToolbarHeight + 15),
                    _glassSearchBar(),
                    Expanded(
                      child: (activeCategory == null && searchQuery.isEmpty)
                          ? _categoryGrid()
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (activeCategory != null)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 8),
                                    child: Text(
                                      "Category: $activeCategory",
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 18,
                                      ),
                                    ),
                                  ),
                                Expanded(child: _productGrid()),
                              ],
                            ),
                    ),
                  ],
                ),
        ),
        bottomNavigationBar: isStoreOpen && cart.isNotEmpty
            ? Container(
                padding: const EdgeInsets.fromLTRB(15, 10, 15, 25),
                decoration: const BoxDecoration(
                  color: brandColor,
                  borderRadius: BorderRadius.all(Radius.circular(18)),
                  boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 20)],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // --- 1. SMART PEEK (PROGRESS BAR) ---
                    Builder(builder: (context) {
                      double itemsTotal = cart.values.fold(0.0, (sum, e) {
                        final p = e['item'];
                        final price = double.tryParse(
                                (p['selling_price'] ?? p['price'])
                                    .toString()) ??
                            0.0;
                        return sum + (price * e['qty']);
                      });

                      const double threshold = 300.0; // Free delivery goal
                      double progress =
                          (itemsTotal / threshold).clamp(0.0, 1.0);
                      bool isFree = itemsTotal >= threshold;

                      return Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                isFree
                                    ? "🎉 Free Delivery Unlocked!"
                                    : "Add ₹${(threshold - itemsTotal).toInt()} for Free Delivery",
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold),
                              ),
                              Text("${(progress * 100).toInt()}%",
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 11)),
                            ],
                          ),
                          const SizedBox(height: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: LinearProgressIndicator(
                              value: progress,
                              backgroundColor: Colors.white24,
                              color: Colors.white,
                              minHeight: 4,
                            ),
                          ),
                        ],
                      );
                    }),

                    const SizedBox(height: 12),

                    // --- 2. TOTAL AND VIEW CART BUTTON ---
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Builder(builder: (context) {
                          double total = cart.values.fold(0.0, (sum, e) {
                            final p = e['item'];
                            final price = double.tryParse(
                                    (p['selling_price'] ?? p['price'])
                                        .toString()) ??
                                0.0;
                            return sum + (price * e['qty']);
                          });
                          return Text("₹${total.toInt()}",
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold));
                        }),
                        ElevatedButton(
                          onPressed: () {
                            HapticFeedback.mediumImpact();
                            _openAddressPage();
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: brandColor,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 10),
                          ),
                          child: const Text("VIEW CART",
                              style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ],
                ),
              )
            : null,
      ),
    );
  }

  Widget _closedView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.storefront, size: 100, color: Colors.white),
          const SizedBox(height: 20),
          const Text(
            "Store is currently closed",
            style: TextStyle(
                color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const Text(
            "We'll be back soon!",
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 4),
          const Text(
            "Opens tomorrow at 8:00 AM",
            style: TextStyle(
              color: Colors.white70,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _glassAppBar() {
    final bool showingResults =
        activeCategory != null || searchQuery.isNotEmpty;

    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      leading: showingResults
          ? IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () {
                setState(() {
                  activeCategory = null;
                  searchQuery = "";
                });
              },
            )
          : null,
      title: Image.asset('assets/logo.png', height: 96),
      flexibleSpace: ClipRRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            color: Colors.white
                .withOpacity(0.1), // Lower opacity for better glass effect
          ),
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.support_agent, color: Colors.white),
          onPressed: _showSupport,
        ),
        IconButton(
          icon: const Icon(Icons.admin_panel_settings, color: Colors.white),
          onPressed: widget.onAdmin,
        ),
      ],
    );
  }

  Widget _glassSearchBar() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(30),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: TextField(
            onChanged: (v) {
              _debounce?.cancel();
              _debounce = Timer(
                const Duration(milliseconds: 350),
                () => setState(() => searchQuery = v),
              );
            },
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search, color: Colors.white),
              hintText: "Search products",
              hintStyle: const TextStyle(color: Colors.white70),
              filled: true,
              fillColor: Colors.white.withOpacity(0.25),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(30),
                borderSide: BorderSide.none,
              ),
            ),
            style: const TextStyle(color: Colors.white),
          ),
        ),
      ),
    );
  }

  Widget _categoryGrid() {
    return FutureBuilder(
      future: _categories(),
      builder: (_, snap) {
        if (snap.hasError) {
          return Center(child: Text("Error: ${snap.error}"));
        }

        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final cats = snap.data!;
        return GridView.builder(
          padding: const EdgeInsets.all(10),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: cats.length,
          itemBuilder: (_, i) {
            final c = cats[i];
            return GestureDetector(
              onTap: () => setState(() => activeCategory = c['name']),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Image.network(
                        c['image_url'] ?? '',
                        fit: BoxFit.cover,
                      ),
                    ),
                    Container(
                      alignment: Alignment.bottomCenter,
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            Colors.black.withOpacity(0.5),
                            Colors.transparent,
                          ],
                        ),
                      ),
                      child: Text(
                        c['name'],
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ================= IMPROVED PRODUCT GRID =================

  Widget _productGrid() {
    return FutureBuilder(
      future: _products(),
      builder: (_, snap) {
        if (!snap.hasData)
          return const Center(
              child: CircularProgressIndicator(color: brandColor));
        final list = snap.data!;
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 120),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            childAspectRatio: 0.64,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: list.length,
          itemBuilder: (_, i) {
            final p = list[i];
            final id = p['id'].toString();
            final qty = cart[id]?['qty'] ?? 0;
            final price = _price(p);

            // Inside your GridView.builder -> item builder
            return Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(15),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.04), blurRadius: 8)
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. SMALLER IMAGE + ROUNDED CORNERS
                  Padding(
                    padding:
                        const EdgeInsets.all(12.0), // Shrinks the image size
                    child: ClipRRect(
                      borderRadius:
                          BorderRadius.circular(15), // Rounds the image corners
                      child: AspectRatio(
                        aspectRatio: 1.1,
                        child: Image.network(
                          p['image_url'] ?? '',
                          fit: BoxFit
                              .cover, // Ensures the image fills the rounded box
                        ),
                      ),
                    ),
                  ),

                  // 2. CONTENT AREA
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(10.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // FIXED HEIGHT NAME SECTION (Crucial for uniformity)
                          SizedBox(
                            height: 38, // Enough for 2 lines of text
                            child: Text(
                              p['name'] ?? '',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                          ),
                          Text(p['unit'] ?? '',
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey)),

                          const Spacer(), // Pushes the price and button to the very bottom
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text("₹${price['final']}",
                                      style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold)),
                                  if (price['has'])
                                    Text("₹${price['mrp']}",
                                        style: const TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey,
                                            decoration:
                                                TextDecoration.lineThrough)),
                                ],
                              ),
                              // THE STYLIZED BUTTON
                              qty == 0
                                  ? _buildAddButton(id, p)
                                  : _qtyControls(id, qty),
                            ],
                          )
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // RE-ADDING THE MISSING HELPER: ADD BUTTON

  Widget _buildAddButton(String id, Map p) {
    return Container(
      width: 70, // Fixed width for uniformity
      height: 32,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          )
        ],
      ),
      child: InkWell(
        onTap: () {
          HapticFeedback.lightImpact();
          setState(() => cart[id] = {'item': p, 'qty': 1});
        },
        borderRadius: BorderRadius.circular(8),
        child: const Center(
          child: Text(
            "ADD",
            style: TextStyle(
              color: brandColor,
              fontWeight: FontWeight.w900,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }

  // RE-ADDING THE MISSING HELPER: QTY CONTROLS

  Widget _qtyControls(String id, int qty) {
    return Container(
      width: 70, // Matches the ADD button width exactly
      height: 32,
      decoration: BoxDecoration(
        color: brandColor,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: brandColor.withOpacity(0.3),
            blurRadius: 4,
            offset: const Offset(0, 2),
          )
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // MINUS
          GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              setState(() => qty == 1 ? cart.remove(id) : cart[id]!['qty']--);
            },
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Icon(Icons.remove, size: 16, color: Colors.white),
            ),
          ),
          // NUMBER
          Text(
            "$qty",
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              color: Colors.white,
              fontSize: 13,
            ),
          ),
          // PLUS
          GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              setState(() => cart[id]!['qty']++);
            },
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Icon(Icons.add, size: 16, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer() {
    double total = 0;
    cart.forEach((_, v) => total += _price(v['item'])['final'] * v['qty']);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (cart.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: ElevatedButton(
              onPressed: _openAddressPage,
              child: Text("Checkout ₹$total"),
            ),
          ),
        const Padding(
          padding: EdgeInsets.all(6),
          child: Text(
            "FlashCart · 2026",
            style: TextStyle(fontSize: 11),
          ),
        ),
      ],
    );
  }

  void _openAddressPage() {
    showDialog(
      context: context,
      builder: (_) => _AddressPage(this),
    );
  }

  Future<void> _placeOrder(
    double itemsTotal,
    double delivery,
    double grand,
  ) async {
    if (!_serviceable(addrCtrl.text)) {
      showDialog(
        context: context,
        builder: (_) => const AlertDialog(
          title: Text("Service Not Available"),
          content: Text("We do not deliver to this area."),
        ),
      );
      return;
    }

    await supabase.from('orders').insert({
      'customer_name': nameCtrl.text,
      'phone': phoneCtrl.text,
      'address': addrCtrl.text,
      'items_json': cart.values.toList(),
      'total_amount': grand,
      'delivery_charge': delivery,
      'status': 'Pending',
    });
  }

  Future<void> _sendPushbullet(
    double items,
    double delivery,
    double grand,
  ) async {
    final itemsText = cart.values
        .map((v) =>
            "• ${v['item']['name']} x${v['qty']} = ₹${(_price(v['item'])['final'] * v['qty']).toStringAsFixed(2)}")
        .join("\n");

    try {
      final response = await Supabase.instance.client.functions.invoke(
        'send-push',
        body: {
          'type': 'note',
          'title': '🛒 New Order: ${nameCtrl.text}',
          'body': 'Customer: ${nameCtrl.text}\n'
              'Phone: ${phoneCtrl.text}\n'
              'Address: ${addrCtrl.text}\n\n'
              'Items:\n$itemsText\n\n'
              'Delivery: ₹$delivery\n'
              'Total: ₹$grand',
        },
      );

      print("Edge Function Response: ${response.data}");
    } catch (e) {
      print("Push Error: $e");
    }
  }

  void _showSupport() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        contentPadding: const EdgeInsets.all(20),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.verified_user, color: brandColor, size: 40),
            const SizedBox(height: 15),
            const Text("FlashCart Support",
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
            const Text("Ranipet Operations",
                style: TextStyle(color: Colors.grey, fontSize: 13)),
            const Divider(height: 30),

            // Row layout for a cleaner look
            _supportInfoRow("Store Name:", "Flash Cart"),
            _supportInfoRow("Contact:", "9363498703"),
            _supportInfoRow("Support:", "WhatsApp or call for Queries"),

            const SizedBox(height: 20),

            // This button makes it look like a real system
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: brandColor)),
                child: const Text("CLOSE",
                    style: TextStyle(
                        color: brandColor, fontWeight: FontWeight.bold)),
              ),
            )
          ],
        ),
      ),
    );
  }

// Helper for the rows
  Widget _supportInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
          Text(value,
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
        ],
      ),
    );
  }
}

// ================= ADDRESS PAGE (CENTERED CARD) =================
class _AddressPage extends StatelessWidget {
  final _CustomerHomeState parent;
  const _AddressPage(this.parent);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        child: Dialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text("Delivery Details",
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: brandColor)),
                const SizedBox(height: 20),
                TextField(
                    controller: parent.nameCtrl,
                    decoration: const InputDecoration(
                        labelText: "Name", prefixIcon: Icon(Icons.person))),
                const SizedBox(height: 12),
                TextField(
                    controller: parent.phoneCtrl,
                    keyboardType: TextInputType.phone,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(10),
                    ],
                    decoration: const InputDecoration(
                        labelText: "Phone", prefixIcon: Icon(Icons.phone))),
                const SizedBox(height: 12),
                TextField(
                    controller: parent.addrCtrl,
                    maxLines: 2,
                    decoration: const InputDecoration(
                        labelText: "Address",
                        prefixIcon: Icon(Icons.location_on))),
                const SizedBox(height: 24),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: brandColor,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 50)),
                  onPressed: () {
                    Navigator.pop(context);
                    showDialog(
                        context: context,
                        builder: (_) => Dialog(
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20)),
                            child: _ReviewPage(parent)));
                  },
                  child: const Text("Next"),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ================= REVIEW PAGE =================
class _ReviewPage extends StatelessWidget {
  final _CustomerHomeState parent;
  const _ReviewPage(this.parent);
  static bool _placingOrder = false;

  @override
  Widget build(BuildContext context) {
    double itemsTotal = 0;
    parent.cart.forEach(
        (_, v) => itemsTotal += parent._price(v['item'])['final'] * v['qty']);
    final delivery = itemsTotal >= freeDeliveryThreshold ? 0.0 : deliveryFee;
    final grand = itemsTotal + delivery;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(20)),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Confirm Order",
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const Divider(),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text("Deliver To:"),
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("Edit"))
            ]),
            Text(
                "${parent.nameCtrl.text}\n${parent.phoneCtrl.text}\n${parent.addrCtrl.text}",
                textAlign: TextAlign.center),
            const Divider(),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text("Items:"),
              TextButton(
                  onPressed: () =>
                      Navigator.popUntil(context, (route) => route.isFirst),
                  child: const Text("Edit Cart"))
            ]),

            // --- NEW PRICE BREAKDOWN ---
            const SizedBox(height: 8),
            ...parent.cart.values.map((v) {
              final item = v['item'];
              final qty = v['qty'];
              final price = parent._price(item)['final'];
              final unit = item['unit'] ?? '';

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        "${item['name']} ($qty $unit)",
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                    Text(
                      "₹${(price * qty).toStringAsFixed(2)}",
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              );
            }).toList(),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Items Total", style: TextStyle(color: Colors.grey)),
                Text("₹${itemsTotal.toStringAsFixed(2)}"),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Delivery Fee",
                    style: TextStyle(color: Colors.grey)),
                Text(
                  delivery == 0 ? "FREE" : "₹${delivery.toStringAsFixed(2)}",
                  style: TextStyle(
                    color: delivery == 0 ? Colors.green : Colors.black,
                    fontWeight:
                        delivery == 0 ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("TOTAL TO PAY",
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  Text(
                    "₹${grand.toStringAsFixed(2)}",
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: brandColor,
                    ),
                  ),
                ],
              ),
            ),
            // --- END OF PRICE BREAKDOWN ---

            // --- ADDED PAYMENT METHOD INFO BOX ---
            Container(
              margin: const EdgeInsets.symmetric(vertical: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue.withOpacity(0.2)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.payments_outlined,
                      color: Colors.blue, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "PAYMENT METHOD",
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.blue,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const Text(
                          "Pay via Cash or UPI upon Delivery",
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // --- END OF PAYMENT BOX ---

            const SizedBox(height: 10), // Adjusted spacing
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white),
                onPressed: () async {
                  // --- START OF SERVICEABILITY CHECK ---
                  if (!parent._serviceable(parent.addrCtrl.text)) {
                    HapticFeedback.vibrate();

                    showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder: (ctx) => AlertDialog(
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20)),
                        title: const Row(
                          children: [
                            Icon(Icons.location_off, color: Colors.red),
                            SizedBox(width: 10),
                            Text("Area Not Covered",
                                style: TextStyle(fontWeight: FontWeight.bold)),
                          ],
                        ),
                        content: const Text(
                          "Oops! FlashCart currently only delivers to Ranipet, BHEL, Arcot, and nearby areas.\n\nPlease check your address for typos or contact support.",
                          style: TextStyle(fontSize: 14),
                        ),
                        actions: [
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: brandColor,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text("GO BACK"),
                          ),
                        ],
                      ),
                    );
                    return;
                  }
                  // --- END OF SERVICEABILITY CHECK ---

                  try {
                    await parent._placeOrder(itemsTotal, delivery, grand);

                    if (context.mounted) {
                      parent.setState(() => parent.cart.clear());

                      Navigator.popUntil(context, (route) => route.isFirst);

                      showDialog(
                        context: context,
                        barrierDismissible: false,
                        builder: (ctx) {
                          Future.delayed(const Duration(seconds: 2), () {
                            if (ctx.mounted) Navigator.pop(ctx);
                          });

                          return Center(
                            child: Material(
                              color: Colors.transparent,
                              child: Container(
                                width: 180,
                                height: 180,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(24),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.2),
                                      blurRadius: 20,
                                      offset: const Offset(0, 10),
                                    )
                                  ],
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: brandColor.withOpacity(0.1),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(
                                        Icons.check_circle_rounded,
                                        color: brandColor,
                                        size: 60,
                                      ),
                                    ),
                                    const SizedBox(height: 15),
                                    const Text(
                                      "Order Placed!",
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.black87,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    const Text(
                                      "FlashCart Ranipet",
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    }
                  } catch (e) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text("Error: $e")));
                  }
                },
                child: const Text("PLACE ORDER NOW"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AdminDashboard extends StatefulWidget {
  final VoidCallback onBack;
  const AdminDashboard({super.key, required this.onBack});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  bool storeOpen = true;
  final supabase = Supabase.instance.client;
  String normalizeIndianPhone(String input) {
    String digits = input.replaceAll(RegExp(r'[^0-9]'), '');

    // Remove leading zero (very common in India)
    if (digits.startsWith('0')) {
      digits = digits.substring(1);
    }

    // If customer typed only 10 digits, assume India
    if (digits.length == 10) {
      digits = '91$digits';
    }

    return digits;
  }

  @override
  void initState() {
    super.initState();
    _getStoreInitial();
  }

  void _getStoreInitial() async {
    final res = await supabase
        .from('store_settings')
        .select()
        .eq('id', 1)
        .maybeSingle();
    if (res != null) setState(() => storeOpen = res['is_open']);
  }

  // Helper function to launch the phone dialer
  Future<void> _makeCall(String phoneNumber) async {
    final Uri launchUri = Uri(
      scheme: 'tel',
      path: phoneNumber,
    );
    if (await canLaunchUrl(launchUri)) {
      await launchUrl(launchUri);
    } else {
      debugPrint('Could not launch $launchUri');
    }
  }

  @override
  Widget build(BuildContext context) {
    Future<void> _sendWhatsAppReceipt({
      required String phone,
      required String name,
      required List items,
      required double total,
      required String address,
    }) async {
      String itemSummary = items.map((i) {
        final itemName = i['item']['name'] ?? 'Item';
        final qty = i['qty'] ?? 1;
        return "• $itemName x$qty";
      }).join("\n");

      final message = """
*ORDER RECEIVED!* ⚡

Hi *$name*, we've received your order and will deliver it to you in a flash!

*Order Details:*
$itemSummary

*Total:* ₹$total
*Address:* $address

Thank you for shopping with us!""";

      final cleanPhone = normalizeIndianPhone(phone);

      if (cleanPhone.length != 12) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Invalid phone number")),
        );
        return;
      }

      final url =
          "https://wa.me/$cleanPhone?text=${Uri.encodeComponent(message)}";

      await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    }

    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        leading: IconButton(
            icon: const Icon(Icons.arrow_back), onPressed: widget.onBack),
        title: const Text("Manager Panel",
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        actions: [
          Row(
            children: [
              Text(storeOpen ? "OPEN " : "CLOSED ",
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: storeOpen ? Colors.green : Colors.red)),
              Switch(
                value: storeOpen,
                activeColor: Colors.green,
                onChanged: (v) async {
                  setState(() => storeOpen = v);
                  await supabase
                      .from('store_settings')
                      .update({'is_open': v}).eq('id', 1);
                },
              ),
            ],
          ),
        ],
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: supabase
            .from('orders')
            .stream(primaryKey: ['id']).order('id', ascending: false),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text("Error: ${snap.error}"));
          }

          if (snap.connectionState == ConnectionState.waiting) {
            // Using Colors.orange instead of brandColor to rule out variable errors
            return const Center(
                child: CircularProgressIndicator(color: Colors.orange));
          }

          final orders = snap.data ?? [];

          if (orders.isEmpty) {
            return const Center(
              child:
                  Text("No orders found", style: TextStyle(color: Colors.grey)),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 20, top: 10),
            itemCount: orders.length,
            itemBuilder: (_, index) {
              final o = orders[index];

              // FIX 1: Null-safe cast for items
              final items = (o['items_json'] as List?) ?? [];

              // FIX 2: Null-safe cast for total
              final grandTotal = (o['total_amount'] as num?)?.toDouble() ?? 0.0;

              final isDelivered = o['status'] == 'Delivered';

              // FIX 3: Robust string conversion for phone
              final phone = (o['phone'] ?? '').toString();
              final fcfsNumber = orders.length - index;

              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                color: isDelivered ? Colors.green[50] : Colors.white,
                child: ExpansionTile(
                  leading: CircleAvatar(
                    // Using Colors.orange here to ensure it doesn't crash if brandColor is missing
                    backgroundColor: isDelivered ? Colors.green : Colors.orange,
                    child: Text("$fcfsNumber",
                        style:
                            const TextStyle(color: Colors.white, fontSize: 12)),
                  ),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(o['customer_name'] ?? 'Customer',
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: isDelivered ? Colors.green : Colors.orange,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          isDelivered ? "DELIVERED" : "PENDING",
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 8,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                  subtitle: Text("Total: ₹$grandTotal · $phone"),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text("CUSTOMER INFO",
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.grey)),
                          const SizedBox(height: 8),
                          InkWell(
                            onTap: () => _makeCall(phone),
                            child: Row(
                              children: [
                                const Icon(Icons.phone,
                                    size: 18, color: Colors.blue),
                                const SizedBox(width: 8),
                                Text(phone,
                                    style: const TextStyle(
                                        fontSize: 16,
                                        color: Colors.blue,
                                        decoration: TextDecoration.underline)),
                                const Spacer(),
                                const Text("Tap to Call",
                                    style: TextStyle(
                                        fontSize: 10, color: Colors.grey)),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          InkWell(
                            onTap: () => _sendWhatsAppReceipt(
                              phone: phone,
                              name: o['customer_name'] ?? 'Customer',
                              items: items,
                              total: grandTotal,
                              address: o['address'] ?? 'No Address',
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.message,
                                    size: 18, color: Colors.green),
                                const SizedBox(width: 8),
                                const Text("Send WhatsApp Receipt",
                                    style: TextStyle(
                                        fontSize: 16,
                                        color: Colors.green,
                                        fontWeight: FontWeight.w500)),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text("📍 ${o['address'] ?? 'No Address'}",
                              style: const TextStyle(fontSize: 14)),
                          const Divider(height: 24),
                          const Text("ITEMS",
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.grey)),
                          const SizedBox(height: 8),
                          // FIX 4: Ensure items.map doesn't crash if an item structure is weird
                          ...items.map((i) {
                            final itemData = i['item'] ?? {};
                            final itemName = itemData['name'] ?? 'Unknown Item';
                            final qty = i['qty'] ?? 0;
                            final price = (itemData['selling_price'] ??
                                itemData['price'] ??
                                0);
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text("$itemName x$qty",
                                      style: const TextStyle(fontSize: 14)),
                                  Text("₹${price * qty}"),
                                ],
                              ),
                            );
                          }).toList(),
                          const Divider(height: 24),
                          if (!isDelivered)
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                icon: const Icon(Icons.check_circle_outline),
                                label: const Text("MARK AS DELIVERED"),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green,
                                  foregroundColor: Colors.white,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8)),
                                ),
                                onPressed: () async {
                                  await supabase
                                      .from('orders')
                                      .update({'status': 'Delivered'}).eq(
                                          'id', o['id']);
                                },
                              ),
                            )
                          else
                            const Center(
                              child: Text("✅ Order Successfully Delivered",
                                  style: TextStyle(
                                      color: Colors.green,
                                      fontWeight: FontWeight.bold)),
                            ),
                        ],
                      ),
                    )
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
