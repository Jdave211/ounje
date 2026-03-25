import SwiftUI

// MARK: - MealMeCartView

/// Entry-point view for the MealMe in-app grocery flow.
/// Shown when the user taps "Order Ingredients" on a meal plan or recipe.
///
/// Flow:
///   1. Searching  →  server calls MealMe for nearby stores + matched products
///   2. Store pick →  user picks cheapest / best-match / fastest store
///   3. Confirm    →  server creates a MealMe cart, returns cartId + totals
///   4. Place order →  payment sheet (Phase 2)
struct MealMeCartView: View {
    let items: [GroceryItem]
    let recipeTitle: String?
    let recipeImageURL: String?
    let recipeID: String?
    let deliveryAddress: DeliveryAddress?

    @StateObject private var vm: MealMeCartViewModel
    @Environment(\.dismiss) private var dismiss

    init(
        items: [GroceryItem],
        recipeTitle: String? = nil,
        recipeImageURL: String? = nil,
        recipeID: String? = nil,
        deliveryAddress: DeliveryAddress? = nil
    ) {
        self.items = items
        self.recipeTitle = recipeTitle
        self.recipeImageURL = recipeImageURL
        self.recipeID = recipeID
        self.deliveryAddress = deliveryAddress
        _vm = StateObject(wrappedValue: MealMeCartViewModel())
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.background.ignoresSafeArea()

                switch vm.flowState {
                case .idle:
                    Color.clear.onAppear { startSearch() }

                case .searching:
                    SearchingView()

                case .storeSelection(let stores):
                    StoreSelectionView(stores: stores, vm: vm)

                case .loadingQuote(let store):
                    QuoteLoadingView(store: store)

                case .readyToOrder(let store, let quote):
                    OrderConfirmView(store: store, quote: quote, vm: vm)

                case .creatingCart:
                    CreatingCartView()

                case .cartReady(let cartId, let total):
                    CartReadyView(cartId: cartId, total: total, storeName: vm.selectedStore?.storeName)

                case .fallback(let url):
                    FallbackView(url: url)

                case .error(let msg):
                    ErrorView(message: msg, onRetry: startSearch)
                }
            }
            .navigationTitle(recipeTitle ?? "Order Ingredients")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Palette.navBar, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Palette.secondaryText)
                }
            }
        }
    }

    private func startSearch() {
        vm.search(
            items: items,
            deliveryAddress: deliveryAddress,
            recipeTitle: recipeTitle,
            recipeImageURL: recipeImageURL,
            recipeID: recipeID
        )
    }
}

// MARK: - Searching

private struct SearchingView: View {
    @State private var dots = ""
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView()
                .progressViewStyle(.circular)
                .tint(Palette.accent)
                .scaleEffect(1.4)

            VStack(spacing: 8) {
                Text("Finding nearby stores\(dots)")
                    .font(.headline)
                    .foregroundStyle(Palette.primaryText)
                Text("Matching your ingredients across 1M+ stores")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding()
        .onReceive(timer) { _ in
            dots = dots.count < 3 ? dots + "." : ""
        }
    }
}

// MARK: - Store selection

private struct StoreSelectionView: View {
    let stores: [MealMeStoreOption]
    @ObservedObject var vm: MealMeCartViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                headerBadge
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                ForEach(Array(stores.enumerated()), id: \.element.id) { index, store in
                    StoreOptionCard(
                        store: store,
                        badge: badge(for: index),
                        isSelected: vm.selectedStore?.storeId == store.storeId
                    )
                    .onTapGesture { vm.selectStore(store) }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }

                if let selected = vm.selectedStore {
                    ProductListSection(store: selected)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    checkoutButton(store: selected)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 32)
                }
            }
        }
    }

    private var headerBadge: some View {
        HStack {
            Image(systemName: "storefront.fill")
                .foregroundStyle(Palette.accent)
            Text("\(stores.count) stores found near you")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.primaryText)
            Spacer()
        }
        .padding(12)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private func badge(for index: Int) -> StoreBadge? {
        switch index {
        case 0: return .bestMatch
        case 1: return stores.count > 2 ? .cheapest : nil
        default: return nil
        }
    }

    private func checkoutButton(store: MealMeStoreOption) -> some View {
        Button {
            vm.proceedToCheckout()
        } label: {
            Label("Order from \(store.storeName)", systemImage: "bag.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Palette.accent, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

private enum StoreBadge: String {
    case bestMatch = "Best Match"
    case cheapest  = "Cheapest"
    case fastest   = "Fastest"

    var color: Color {
        switch self {
        case .bestMatch: return Palette.accent
        case .cheapest:  return Color.green.opacity(0.8)
        case .fastest:   return Color.orange.opacity(0.8)
        }
    }
}

private struct StoreOptionCard: View {
    let store: MealMeStoreOption
    let badge: StoreBadge?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            // Logo placeholder
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Palette.elevated)
                    .frame(width: 52, height: 52)
                if let logo = store.logoUrl, let url = URL(string: logo) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        default:
                            storeInitial
                        }
                    }
                } else {
                    storeInitial
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(store.storeName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.primaryText)
                    if let badge {
                        Text(badge.rawValue)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(badge.color.opacity(0.2), in: Capsule())
                            .foregroundStyle(badge.color)
                    }
                }

                HStack(spacing: 8) {
                    if let dist = store.distanceLabel {
                        Label(dist, systemImage: "location.fill")
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    if let rating = store.ratingLabel {
                        Label(rating, systemImage: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow.opacity(0.9))
                    }
                    if !store.isOpen {
                        Text("Closed")
                            .font(.caption)
                            .foregroundStyle(.red.opacity(0.8))
                    }
                }

                matchBar(store: store)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "~$%.0f", store.subtotalEstimate))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Palette.primaryText)
                Text("est. subtotal")
                    .font(.caption2)
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Palette.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isSelected ? Palette.accent : Palette.stroke, lineWidth: isSelected ? 1.5 : 1)
                )
        )
    }

    private var storeInitial: some View {
        Text(String(store.storeName.prefix(1)))
            .font(.title3.weight(.bold))
            .foregroundStyle(Palette.accent)
    }

    private func matchBar(store: MealMeStoreOption) -> some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.elevated)
                    Capsule()
                        .fill(store.matchRatio > 0.8 ? Palette.accent : Color.orange.opacity(0.7))
                        .frame(width: geo.size.width * store.matchRatio)
                }
            }
            .frame(height: 4)

            Text(store.matchLabel)
                .font(.caption2)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize()
        }
    }
}

// MARK: - Product list

private struct ProductListSection: View {
    let store: MealMeStoreOption
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("Matched items")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.primaryText)
                    Spacer()
                    Text("\(store.matchedCount)/\(store.totalItems)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.accent)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryText)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Palette.panel)
            }

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(store.products) { product in
                        ProductRow(product: product)
                        if product.id != store.products.last?.id {
                            Divider()
                                .overlay(Palette.stroke)
                                .padding(.leading, 52)
                        }
                    }
                }
                .background(Palette.surface)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Palette.stroke, lineWidth: 1)
        )
    }
}

private struct ProductRow: View {
    let product: MealMeProduct

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let imgURL = product.imageUrl.flatMap(URL.init) {
                    AsyncImage(url: imgURL) { phase in
                        if case .success(let img) = phase {
                            img.resizable().scaledToFill()
                        } else {
                            Image(systemName: "bag")
                                .foregroundStyle(Palette.secondaryText)
                        }
                    }
                } else {
                    Image(systemName: "bag")
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(product.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.primaryText)
                    .lineLimit(1)
                if let unit = product.unit {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(Palette.secondaryText)
                }
                if let match = product.queryMatch {
                    Text("For: \(match)")
                        .font(.caption2)
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(product.priceLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.primaryText)
                if !product.inStock {
                    Text("Out of stock")
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Quote loading

private struct QuoteLoadingView: View {
    let store: MealMeStoreOption

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView().tint(Palette.accent).scaleEffect(1.2)
            Text("Getting delivery fee from \(store.storeName)…")
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryText)
            Spacer()
        }
    }
}

// MARK: - Order confirm

private struct OrderConfirmView: View {
    let store: MealMeStoreOption
    let quote: MealMeQuote?
    @ObservedObject var vm: MealMeCartViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Store header
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(Palette.elevated).frame(width: 60, height: 60)
                        Text(String(store.storeName.prefix(1)))
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Palette.accent)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.storeName)
                            .font(.headline)
                            .foregroundStyle(Palette.primaryText)
                        if let addr = store.address {
                            Text(addr)
                                .font(.caption)
                                .foregroundStyle(Palette.secondaryText)
                        }
                    }
                    Spacer()
                }

                // Price breakdown
                VStack(spacing: 0) {
                    priceRow(label: "Subtotal (est.)", value: String(format: "$%.2f", store.subtotalEstimate))
                    Divider().overlay(Palette.stroke).padding(.vertical, 4)
                    priceRow(label: "Delivery fee", value: quote != nil ? String(format: "$%.2f", quote!.deliveryFee) : "Fetching…")
                    if let eta = quote?.etaLabel {
                        Divider().overlay(Palette.stroke).padding(.vertical, 4)
                        priceRow(label: "Estimated arrival", value: eta)
                    }
                    Divider().overlay(Palette.stroke).padding(.vertical, 4)
                    priceRow(
                        label: "Est. total",
                        value: quote != nil
                            ? String(format: "$%.2f", store.subtotalEstimate + quote!.deliveryFee)
                            : "—",
                        bold: true
                    )
                }
                .padding(16)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))

                // Match info
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Palette.accent)
                    Text(store.matchLabel)
                        .font(.subheadline)
                        .foregroundStyle(Palette.primaryText)
                    Spacer()
                }
                .padding(14)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))

                // CTA
                Button {
                    vm.confirmOrder()
                } label: {
                    HStack {
                        if vm.flowState.isCreatingCart {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "bag.badge.plus")
                        }
                        Text("Confirm Cart")
                            .font(.headline)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(quote != nil ? Palette.accent : Palette.elevated)
                    )
                }
                .disabled(quote == nil)

                Button("Choose a different store") {
                    vm.backToStoreSelection()
                }
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryText)
            }
            .padding(20)
        }
    }

    private func priceRow(label: String, value: String, bold: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(bold ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundStyle(bold ? Palette.primaryText : Palette.secondaryText)
            Spacer()
            Text(value)
                .font(bold ? .subheadline.weight(.bold) : .subheadline)
                .foregroundStyle(Palette.primaryText)
        }
    }
}

// MARK: - Creating cart

private struct CreatingCartView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView().tint(Palette.accent).scaleEffect(1.2)
            Text("Locking in your cart…")
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryText)
            Spacer()
        }
    }
}

// MARK: - Cart ready

private struct CartReadyView: View {
    let cartId: String
    let total: Double?
    let storeName: String?

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "bag.fill.badge.checkmark")
                .font(.system(size: 64))
                .foregroundStyle(Palette.accent)

            VStack(spacing: 8) {
                Text("Cart created!")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Palette.primaryText)
                if let name = storeName {
                    Text("at \(name)")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondaryText)
                }
                if let total {
                    Text(String(format: "Est. total: $%.2f", total))
                        .font(.headline)
                        .foregroundStyle(Palette.accent)
                }
            }

            // Placeholder for payment CTA (Phase 2)
            VStack(spacing: 12) {
                Text("Payment integration coming soon.")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)

                Text("Cart ID: \(cartId)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(Palette.secondaryText)
            }
            .padding(16)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 32)

            Spacer()
        }
        .padding()
    }
}

// MARK: - Fallback

private struct FallbackView: View {
    let url: URL

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: 52))
                .foregroundStyle(Palette.accent)
            Text("Opening external store")
                .font(.headline)
                .foregroundStyle(Palette.primaryText)
            Text("We'll open a store search so you can add items manually.")
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Link(destination: url) {
                Text("Open in Browser")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 32)
            Spacer()
        }
    }
}

// MARK: - Error

private struct ErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 52))
                .foregroundStyle(.orange)
            Text("Something went wrong")
                .font(.headline)
                .foregroundStyle(Palette.primaryText)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button(action: onRetry) {
                Text("Try Again")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 32)
            Spacer()
        }
    }
}

// MARK: - ViewModel

@MainActor
final class MealMeCartViewModel: ObservableObject {
    @Published var flowState: MealMeFlowState = .idle
    @Published var selectedStore: MealMeStoreOption?

    private var storeOptions: [MealMeStoreOption] = []
    private var pendingQuote: MealMeQuote?
    private var lastLocation: MealMeLocation?
    private var lastAddress: DeliveryAddress?

    private let service = GroceryService.shared

    func search(
        items: [GroceryItem],
        deliveryAddress: DeliveryAddress?,
        recipeTitle: String?,
        recipeImageURL: String?,
        recipeID: String?
    ) {
        lastAddress = deliveryAddress
        flowState = .searching

        Task {
            do {
                let response = try await service.searchMealMeCart(
                    items: items,
                    deliveryAddress: deliveryAddress,
                    recipeTitle: recipeTitle,
                    recipeImageURL: recipeImageURL,
                    recipeID: recipeID
                )
                lastLocation = response.location
                storeOptions = response.storeOptions

                if response.storeOptions.isEmpty {
                    // Fallback
                    let fallback = URL(string: "https://www.walmart.com")!
                    flowState = .fallback(url: fallback)
                } else {
                    let top = response.storeOptions[0]
                    selectedStore = top
                    flowState = .storeSelection(response.storeOptions)
                    // Pre-fetch quote for the top store silently
                    prefetchQuote(for: top)
                }
            } catch {
                flowState = .error(error.localizedDescription)
            }
        }
    }

    func selectStore(_ store: MealMeStoreOption) {
        guard store.storeId != selectedStore?.storeId else { return }
        selectedStore = store
        pendingQuote = nil

        if case .storeSelection = flowState {
            // Just update selection — quote will be fetched when user hits proceed
        }

        // Pre-fetch quote silently
        prefetchQuote(for: store)
    }

    func proceedToCheckout() {
        guard let store = selectedStore else { return }

        if let quote = pendingQuote {
            flowState = .readyToOrder(store, quote)
        } else {
            flowState = .loadingQuote(store)
            Task {
                let quotes = try? await service.fetchMealMeQuotes(
                    storeId: store.storeId,
                    address: lastAddress,
                    location: lastLocation
                )
                let quote = quotes?.first(where: { $0.fulfillment == "delivery" }) ?? quotes?.first
                pendingQuote = quote
                flowState = .readyToOrder(store, quote)
            }
        }
    }

    func confirmOrder() {
        guard let store = selectedStore, let quote = pendingQuote else { return }
        flowState = .creatingCart

        Task {
            do {
                let result = try await service.createMealMeCart(
                    storeId: store.storeId,
                    quoteId: quote.quoteId,
                    products: store.products.filter { $0.inStock },
                    deliveryAddress: lastAddress
                )
                flowState = .cartReady(cartId: result.cartId, total: result.total)
            } catch {
                flowState = .error(error.localizedDescription)
            }
        }
    }

    func backToStoreSelection() {
        flowState = .storeSelection(storeOptions)
    }

    private func prefetchQuote(for store: MealMeStoreOption) {
        Task {
            let quotes = try? await service.fetchMealMeQuotes(
                storeId: store.storeId,
                address: lastAddress,
                location: lastLocation
            )
            if selectedStore?.storeId == store.storeId {
                pendingQuote = quotes?.first(where: { $0.fulfillment == "delivery" }) ?? quotes?.first
            }
        }
    }
}

// MARK: - Local palette (mirrors OunjePalette)

private extension Color {
    init(mmHex: String) {
        let cleaned = mmHex.replacingOccurrences(of: "#", with: "")
        let scanner = Scanner(string: cleaned)
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)
        self.init(
            .sRGB,
            red:   Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8)  & 0xFF) / 255,
            blue:  Double(value         & 0xFF) / 255,
            opacity: 1
        )
    }
}

private enum Palette {
    static let background   = Color(mmHex: "121212")
    static let panel        = Color(mmHex: "1E1E1E")
    static let surface      = Color(mmHex: "2E2E2E")
    static let elevated     = Color(mmHex: "383838")
    static let navBar       = Color(mmHex: "282C35")
    static let accent       = Color(mmHex: "1E5A3E")
    static let secondaryText = Color(mmHex: "8A8A8A")
    static let stroke       = Color.white.opacity(0.08)
    static let primaryText  = Color.white
}
