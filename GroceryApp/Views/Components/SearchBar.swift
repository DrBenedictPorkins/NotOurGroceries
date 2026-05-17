//
//  SearchBar.swift
//  GroceryApp
//
//  Created on 2026-01-04.
//  Autocomplete-ready search field with glass morphism design
//

import SwiftUI

/// Glass-style search bar with neon glow on focus and voice input placeholder
struct SearchBar: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    var onSubmit: () -> Void
    var onProductSelected: (Product) -> Void
    var onImport: (() -> Void)? = nil

    @EnvironmentObject var viewModel: ShoppingListViewModel
    @State private var showAutocomplete = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Search icon
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(isFocused ? Color(hex: "00D4FF") : .white.opacity(0.5))
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)

                // Text field
                TextField("Search or add item...", text: $text)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                    .tint(Color(hex: "00D4FF"))
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit {
                        onSubmit()
                        showAutocomplete = false
                    }
                    .onChange(of: text) { oldValue, newValue in
                        updateAutocomplete(for: newValue)
                    }

                // Clear button
                if !text.isEmpty {
                    Button(action: {
                        text = ""
                        showAutocomplete = false
                        hapticFeedback(.light)
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }

                // Import button
                if text.isEmpty, let onImport {
                    Button(action: {
                        hapticFeedback(.light)
                        onImport()
                    }) {
                        Image(systemName: "list.clipboard")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color(hex: "7B2CBF"))
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(searchBarBackground)
            .cornerRadius(20)
            .onTapGesture { isFocused = true }
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(
                        isFocused ? neonGlowGradient : defaultBorderGradient,
                        lineWidth: isFocused ? 2 : 1
                    )
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
            )
            .shadow(
                color: isFocused ? Color(hex: "00D4FF").opacity(0.4) : Color.black.opacity(0.2),
                radius: isFocused ? 12 : 8,
                x: 0,
                y: 4
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)

            // Autocomplete dropdown
            if showAutocomplete && !viewModel.searchResults.isEmpty {
                autocompleteView
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showAutocomplete)
    }

    // MARK: - Search Bar Background

    private var searchBarBackground: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(Color.white.opacity(0.08))
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.12),
                                Color.white.opacity(0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .blur(radius: 10)
            )
    }

    // MARK: - Border Gradients

    private var neonGlowGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(hex: "00D4FF"),
                Color(hex: "7B2CBF")
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var defaultBorderGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.3),
                Color.white.opacity(0.1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Autocomplete View

    private var autocompleteView: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.searchResults.prefix(5)) { product in
                Button(action: {
                    text = product.name
                    onProductSelected(product)
                    showAutocomplete = false
                    hapticFeedback(.light)
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "cart.badge.plus")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color(hex: "00D4FF").opacity(0.7))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(product.name)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.white)

                            Text(product.category)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(.white.opacity(0.5))
                        }

                        Spacer()

                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color(hex: "00D4FF").opacity(0.6))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.05))
                }
                .buttonStyle(.plain)

                if product.id != viewModel.searchResults.prefix(5).last?.id {
                    Divider()
                        .background(Color.white.opacity(0.1))
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.08))
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.12),
                                    Color.white.opacity(0.06)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .blur(radius: 10)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color(hex: "00D4FF").opacity(0.3),
                                    Color.white.opacity(0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: Color(hex: "00D4FF").opacity(0.2), radius: 12, x: 0, y: 8)
        )
        .padding(.top, 8)
    }

    // MARK: - Autocomplete Logic

    private func updateAutocomplete(for query: String) {
        guard !query.isEmpty, query.count >= 2 else {
            showAutocomplete = false
            viewModel.searchResults = []
            return
        }

        // Search locally - instant, no debounce needed
        viewModel.searchProducts(query: query)
        showAutocomplete = !viewModel.searchResults.isEmpty
    }

    // MARK: - Haptic Feedback

    private func hapticFeedback(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        LinearGradient(
            colors: [Color(hex: "1a1a2e"), Color(hex: "16213e")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        VStack {
            SearchBarPreview()
        }
        .padding(20)
    }
}

private struct SearchBarPreview: View {
    @State private var text = ""
    @FocusState private var isFocused: Bool
    @StateObject private var viewModel = ShoppingListViewModel()

    var body: some View {
        SearchBar(
            text: $text,
            isFocused: $isFocused,
            onSubmit: {
                print("Submitted: \(text)")
            },
            onProductSelected: { product in
                print("Selected product: \(product.name)")
            }
        )
        .environmentObject(viewModel)
    }
}
