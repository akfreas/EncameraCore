# EncameraCore

EncameraCore is the core functional source code for the iOS app [Encamera](https://apps.apple.com/us/app/encamera-secret-photo-vault/id1639202616), designed to provide secure file handling and encryption functionalities for iOS devices.
If you are interested in suggesting features for Encamera, please write us a note here: https://encamera.featurebase.app/


## Concept

Encamera was built in an open source way to offer as transparent as possible an iOS photo vault app. We've open sourced this portion of the code - the file handling - for maximum transparency.


## Features

Some of the functionality of Encamera:

- **File Handling and Encryption**: Inside the `Utils` directory are some of the interfaces for file encryption. EncameraCore integrates with SwiftSodium for high-level encryption services. SwiftSodium provides a safe and easy-to-use interface to perform common cryptographic operations on iOS.

- **Key and Credential Management**: `KeychainManager` manages keys and credentials securely via the system keychain.

- **Secret File Handling**: `SecretFileHandler` deals with file chunking, encryption, and metadata management to securely store files.

- **File Access Interface**: `DiskFileAccess` offers a higher-level interface for accessing and processing files generated by the app.

- **Camera Processing**: `Video/PhotoCaptureProcessor` processes inputs from the camera and stores them securely.

- **Camera Configuration**: `CameraConfigurationService` manages all configurations necessary to operate the camera.

## Installation

To integrate EncameraCore into your project, add it as a Swift package:

```swift
dependencies: [
    .package(url: "https://github.com/akfreas/EncameraCore")
]
```

## About Encamera

Why is Encamera different?
* Capture images straight from the app or widget. You don’t need to worry about deleting images from the default gallery anymore!
* No account is needed. Not even your email address!
* No data tracking and no ads. Forever. We promise!
* Intuitive and minimalist design so you could import and take secure images and videos with no hassle
* Open source app. Yes, if you’re into tech stuff you can check our source code.

Basic features:
* Take photos or videos directly from the app, without saving them into your default album first
* Take quick photos from your lockscreen using our widget
* Organise your images into folders
* Import already taken images from your gallery
* Store images on your phone

Encamera’s premium features:
* Unlimited photo storage
* Unlimited number of photo albums
* iCloud storage




