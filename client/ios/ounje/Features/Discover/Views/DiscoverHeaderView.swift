import SwiftUI

struct DiscoverHeaderView: View {
    @Binding var searchText: String
    let filters: [String]
    let selectedFilter: String
    let onSubmitSearch: () -> Void
    let onSelectFilter: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                BiroScriptDisplayText("Discover", size: 31, color: OunjePalette.primaryText)
                Text("Find your next meal")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
            }

            CompactDiscoverSearchField(
                text: $searchText,
                onSubmitSearch: onSubmitSearch
            )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .firstTextBaseline, spacing: 26) {
                    ForEach(filters, id: \.self) { filter in
                        DiscoverPresetTextButton(
                            title: filter,
                            isSelected: selectedFilter == filter
                        ) {
                            onSelectFilter(filter)
                        }
                    }
                }
                .padding(.trailing, 10)
                .padding(.top, 2)
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}
