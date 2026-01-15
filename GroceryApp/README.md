# GroceryApp

A SwiftUI-based iOS grocery shopping application with AWS Amplify backend integration.

## Project Structure

```
GroceryApp/
├── GroceryAppApp.swift          # Main app entry point
├── Models/                       # Data models
│   ├── Aisle.swift
│   ├── Commit.swift
│   ├── GroceryItem.swift
│   ├── Household.swift
│   ├── Product.swift
│   ├── Store.swift
│   └── User.swift
├── Services/                     # Business logic services
│   └── AmplifyService.swift     # AWS Amplify configuration
├── Theme/                        # Design system
│   └── DesignSystem.swift
├── ViewModels/                   # View models
│   └── ShoppingListViewModel.swift
├── Views/                        # SwiftUI views
│   ├── ContentView.swift
│   ├── ShoppingListView.swift
│   ├── AtStoreModeView.swift
│   └── Components/
│       ├── GroceryItemRow.swift
│       ├── SearchBar.swift
│       └── ToastView.swift
├── Assets.xcassets/              # Asset catalog
└── Preview Content/              # Preview assets

```

## Requirements

- iOS 17.0+
- Xcode 15.0+
- Swift 5.9+

## Dependencies

The project uses Swift Package Manager with the following dependencies:

- **amplify-swift** (v2.0+)
  - Amplify
  - AWSAPIPlugin
  - AWSCognitoAuthPlugin
  - AWSDataStorePlugin

## Build Configuration

- **Bundle Identifier**: com.grocery.app
- **Deployment Target**: iOS 17.0
- **Supported Devices**: iPhone, iPad

## Getting Started

1. Open `GroceryApp.xcodeproj` in Xcode
2. Wait for Swift Package Manager to resolve dependencies
3. Select a simulator or device
4. Press Cmd+R to build and run

## Architecture

The app follows an MVVM (Model-View-ViewModel) architecture pattern:

- **Models**: Define the data structures for grocery items, stores, households, etc.
- **Services**: Handle backend communication via AWS Amplify
- **ViewModels**: Manage view state and business logic
- **Views**: SwiftUI views for the user interface
- **Theme**: Centralized design system for consistent styling

## Features

- Shopping list management
- At-store mode for optimized shopping
- Multi-household support
- Real-time synchronization via AWS Amplify
- Dark mode support
