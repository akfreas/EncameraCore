// swiftlint:disable all
// Generated using SwiftGen — https://github.com/SwiftGen/SwiftGen

import Foundation

// swiftlint:disable superfluous_disable_command file_length implicit_return prefer_self_in_static_references

// MARK: - Strings

// swiftlint:disable explicit_type_interface function_parameter_count identifier_name line_length
// swiftlint:disable nesting type_body_length type_name vertical_whitespace_opening_braces
public enum L10n {
  ///  icon in the camera view to change the active key.
  public static let iconInTheCameraViewToChangeTheActiveKey = L10n.tr("Localizable", " icon in the camera view to change the active key.", fallback: " icon in the camera view to change the active key.")
  ///  icon on the top left of the screen.
  public static let iconOnTheTopLeftOfTheScreen = L10n.tr("Localizable", " icon on the top left of the screen.", fallback: " icon on the top left of the screen.")
  /// Plural format key: "%#@file_count@"
  public static func fileS(_ p1: Int) -> String {
    return L10n.tr("Localizable", "%@ File(s)", p1, fallback: "Plural format key: \"%#@file_count@\"")
  }
  /// Plural format key: "%#@image_count@"
  public static func imageS(_ p1: Int) -> String {
    return L10n.tr("Localizable", "%@ Image(s)", p1, fallback: "Plural format key: \"%#@image_count@\"")
  }
  /// Plural format key: "%#@item_count@"
  public static func itemS(_ p1: Int) -> String {
    return L10n.tr("Localizable", "%@ Item(s)", p1, fallback: "Plural format key: \"%#@item_count@\"")
  }
  /// ./EncameraCore/Utils/SettingsManager.swift
  public static func mustBeSet(_ p1: Any) -> String {
    return L10n.tr("Localizable", "%@ must be set", String(describing: p1), fallback: "%@ must be set")
  }
  /// Plural format key: "%#@photo_count@"
  public static func photoSLeft(_ p1: Int) -> String {
    return L10n.tr("Localizable", "%@ Photo(s) Left", p1, fallback: "Plural format key: \"%#@photo_count@\"")
  }
  /// Plural format key: "%#@video_count@"
  public static func videoS(_ p1: Int) -> String {
    return L10n.tr("Localizable", "%@ Video(s)", p1, fallback: "Plural format key: \"%#@video_count@\"")
  }
  /// ./Encamera/Store/PurchaseUpgradeOptionsListView.swift
  public static func purchased(_ p1: Any) -> String {
    return L10n.tr("Localizable", "**Purchased: %@**", String(describing: p1), fallback: "**Purchased: %@**")
  }
  /// A key with this name already exists.
  public static let aKeyWithThisNameAlreadyExists = L10n.tr("Localizable", "A key with this name already exists.", fallback: "A key with this name already exists.")
  /// ./Encamera/Camera/AlertError.swift
  public static let accept = L10n.tr("Localizable", "Accept", fallback: "Accept")
  /// Active
  public static let active = L10n.tr("Localizable", "Active", fallback: "Active")
  /// ./Encamera/KeyManagement/AlbumList.swift
  public static let addExistingKey = L10n.tr("Localizable", "Add Existing Key", fallback: "Add Existing Key")
  /// ./Encamera/KeyManagement/KeyOperationCell.swift
  public static let addKey = L10n.tr("Localizable", "Add Key", fallback: "Add Key")
  /// Add Permissions
  public static let addPermissions = L10n.tr("Localizable", "Add Permissions", fallback: "Add Permissions")
  /// Add Photos
  public static let addPhotos = L10n.tr("Localizable", "AddPhotos", fallback: "Add Photos")
  /// ADD PHOTOS TO THIS ALBUM
  public static let addPhotosToThisAlbum = L10n.tr("Localizable", "AddPhotosToThisAlbum", fallback: "ADD PHOTOS TO THIS ALBUM")
  /// An album with that name already exists.
  public static let albumExistsError = L10n.tr("Localizable", "AlbumExistsError", fallback: "An album with that name already exists.")
  /// Album Name
  public static let albumName = L10n.tr("Localizable", "AlbumName", fallback: "Album Name")
  /// Album name must be longer than 1 character
  public static let albumNameInvalid = L10n.tr("Localizable", "AlbumNameInvalid", fallback: "Album name must be longer than 1 character")
  /// AlbumManager
  public static let albumNotFoundAtSourceLocation = L10n.tr("Localizable", "AlbumNotFoundAtSourceLocation", fallback: "Could not find the album at the source location. Use the Files app to ensure that it exists.")
  /// AlbumGrid
  public static let albumsTitle = L10n.tr("Localizable", "AlbumsTitle", fallback: "Albums")
  /// Are you sure you want to erase ALL ENCAMERA DATA?
  /// 
  /// THIS WILL ERASE:
  /// 
  /// • ALL your stored keys 🔑
  /// • Your password 🔐
  /// • App settings 🎛
  /// • MEDIA YOU HAVE STORED LOCALLY OR ON iCLOUD
  /// 
  /// You can create a backup of your keys from the key management screen.
  /// 
  /// The app will quit after erase is finished.
  public static let allDataExplanation = L10n.tr("Localizable", "allDataExplanation", fallback: "Are you sure you want to erase ALL ENCAMERA DATA?\n\nTHIS WILL ERASE:\n\n• ALL your stored keys 🔑\n• Your password 🔐\n• App settings 🎛\n• MEDIA YOU HAVE STORED LOCALLY OR ON iCLOUD\n\nYou can create a backup of your keys from the key management screen.\n\nThe app will quit after erase is finished.")
  /// Are you sure you want to erase ALL app data?
  /// 
  /// THIS WILL ERASE:
  /// 
  /// • ALL your stored keys 🔑
  /// • Your password 🔐
  /// • App settings 🎛
  /// 
  /// THIS WILL NOT ERASE:
  /// 
  /// • Media you have stored locally or on iCloud
  /// 
  /// You can create a backup of your keys from the key management screen.
  /// 
  /// The app will quit after erase is finished.
  /// 
  /// 
  public static let appDataExplanation = L10n.tr("Localizable", "appDataExplanation", fallback: "Are you sure you want to erase ALL app data?\n\nTHIS WILL ERASE:\n\n• ALL your stored keys 🔑\n• Your password 🔐\n• App settings 🎛\n\nTHIS WILL NOT ERASE:\n\n• Media you have stored locally or on iCloud\n\nYou can create a backup of your keys from the key management screen.\n\nThe app will quit after erase is finished.\n\n")
  /// Passcode Options
  public static let authenticationMethod = L10n.tr("Localizable", "AuthenticationMethod", fallback: "Passcode Options")
  /// Back to album
  public static let backToAlbum = L10n.tr("Localizable", "Back to album", fallback: "Back to album")
  /// Back Up Key
  public static let backUpKey = L10n.tr("Localizable", "Back Up Key", fallback: "Back Up Key")
  /// Backup Keys
  public static let backupKeys = L10n.tr("Localizable", "Backup Keys", fallback: "Backup Keys")
  /// If you lose your key, it is impossible to recover your data. Back up your keys to a password manager after you create them, or save them to iCloud.
  public static let backUpKeysExplanation = L10n.tr("Localizable", "BackUpKeysExplanation", fallback: "If you lose your key, it is impossible to recover your data. Back up your keys to a password manager after you create them, or save them to iCloud.")
  /// Back up those keys!
  public static let backUpKeysHeader = L10n.tr("Localizable", "BackUpKeysHeader", fallback: "Back up those keys!")
  /// Biometrics failed
  public static let biometricsFailed = L10n.tr("Localizable", "Biometrics failed", fallback: "Biometrics failed")
  /// Biometrics unavailable
  public static let biometricsUnavailable = L10n.tr("Localizable", "Biometrics unavailable", fallback: "Biometrics unavailable")
  /// Don't miss out! Deal ends soon!
  public static let blackFridaySubtitle = L10n.tr("Localizable", "BlackFridaySubtitle", fallback: "Don't miss out! Deal ends soon!")
  /// BLACK FRIDAY IS HERE!
  public static let blackFridayTitle = L10n.tr("Localizable", "BlackFridayTitle", fallback: "BLACK FRIDAY IS HERE!")
  /// Buy once. Use forever.
  public static let buyOnceUseForever = L10n.tr("Localizable", "BuyOnceUseForever", fallback: "Buy once. Use forever.")
  /// Cancel
  public static let cancel = L10n.tr("Localizable", "Cancel", fallback: "Cancel")
  /// ShareViewController.swift
  public static let cannotHandleMedia = L10n.tr("Localizable", "Cannot handle media", fallback: "Cannot handle media")
  /// You cannot clear your passcode. You must have Face ID enabled in order to do this.
  public static let cannotClearMessage = L10n.tr("Localizable", "CannotClearMessage", fallback: "You cannot clear your passcode. You must have Face ID enabled in order to do this.")
  /// Cannot Clear Alert
  public static let cannotClearTitle = L10n.tr("Localizable", "CannotClearTitle", fallback: "Cannot Clear")
  /// Change Authentication Method
  public static let changeAuthenticationMethod = L10n.tr("Localizable", "Change Authentication Method", fallback: "Change Authentication Method")
  /// I Want to Choose Another Destination Album
  public static let changeKeyAlbum = L10n.tr("Localizable", "Change Key Album", fallback: "I Want to Choose Another Destination Album")
  /// Change Password
  public static let changePassword = L10n.tr("Localizable", "Change Password", fallback: "Change Password")
  /// Change Passcode
  public static let changePasscode = L10n.tr("Localizable", "ChangePasscode", fallback: "Change Passcode")
  /// Check that the same key that was used to encrypt this media is set as the active key.
  public static let checkThatTheSameKeyThatWasUsedToEncryptThisMediaIsSetAsTheActiveKey = L10n.tr("Localizable", "Check that the same key that was used to encrypt this media is set as the active key.", fallback: "Check that the same key that was used to encrypt this media is set as the active key.")
  /// Choose your login method
  public static let chooseYourLoginMethod = L10n.tr("Localizable", "Choose your login method", fallback: "Choose your login method")
  /// Choose your storage
  public static let chooseYourStorage = L10n.tr("Localizable", "ChooseYourStorage", fallback: "Choose your storage")
  /// Choose where to securely save your images from now on.
  public static let chooseYourStorageDescription = L10n.tr("Localizable", "ChooseYourStorageDescription", fallback: "Choose where to securely save your images from now on.")
  /// Clear
  public static let clear = L10n.tr("Localizable", "Clear", fallback: "Clear")
  /// Authentication Method View
  public static let clearPassword = L10n.tr("Localizable", "Clear Password", fallback: "Clear Password")
  /// Clear saved password/PIN
  public static let clearSavedPasswordPIN = L10n.tr("Localizable", "Clear saved password/PIN", fallback: "Clear saved password/PIN")
  /// Close
  public static let close = L10n.tr("Localizable", "Close", fallback: "Close")
  /// Confirm 6-Digit PIN
  public static let confirm6DigitPIN = L10n.tr("Localizable", "Confirm 6-Digit PIN", fallback: "Confirm 6-Digit PIN")
  /// Confirm adding key
  public static let confirmAddingKey = L10n.tr("Localizable", "Confirm adding key", fallback: "Confirm adding key")
  /// Confirm Pin Code
  public static let confirmPinCode = L10n.tr("Localizable", "ConfirmPinCode", fallback: "Confirm Pin Code")
  /// Confirm Storage
  public static let confirmStorage = L10n.tr("Localizable", "ConfirmStorage", fallback: "Confirm Storage")
  /// ./Encamera/Tutorial/ChooseStorageModal.swift
  public static let congratulations = L10n.tr("Localizable", "Congratulations!", fallback: "Congratulations!")
  /// Continue
  public static let `continue` = L10n.tr("Localizable", "Continue", fallback: "Continue")
  /// Picture taken overlay
  public static let coolPicture = L10n.tr("Localizable", "CoolPicture", fallback: "That's a cool picture!")
  /// Copied to Clipboard
  public static let copiedToClipboard = L10n.tr("Localizable", "Copied to Clipboard", fallback: "Copied to Clipboard")
  /// Copy Phrase to Clipboard
  public static let copyPhrase = L10n.tr("Localizable", "CopyPhrase", fallback: "Copy Phrase to Clipboard")
  /// Write down or copy these words in the right order and save them somewhere safe.
  /// 
  /// This phrase is used to generate the encryption key that encrypts your media.
  /// 
  /// It's important to save this key in case you lose your device.
  public static let copyPhraseInstructions = L10n.tr("Localizable", "CopyPhraseInstructions", fallback: "Write down or copy these words in the right order and save them somewhere safe.\n\nThis phrase is used to generate the encryption key that encrypts your media.\n\nIt's important to save this key in case you lose your device.")
  /// ./EncameraCore/Utils/KeyManager.swift
  public static let couldNotDeleteKeychainItems = L10n.tr("Localizable", "Could not delete keychain items.", fallback: "Could not delete keychain items.")
  /// Could not rename album.
  public static let couldNotRenameAlbumError = L10n.tr("Localizable", "CouldNotRenameAlbumError", fallback: "Could not rename album.")
  /// Create an unlimited number of keys.
  public static let createAnUnlimitedNumberOfKeys = L10n.tr("Localizable", "Create an unlimited number of keys.", fallback: "Create an unlimited number of keys.")
  /// ./Encamera/KeyManagement/KeyInformation.swift
  public static func created(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Created %@", String(describing: p1), fallback: "Created %@")
  }
  /// Create First Album
  public static let createFirstAlbum = L10n.tr("Localizable", "CreateFirstAlbum", fallback: "Create First Album")
  /// Create New Album
  public static let createNewAlbum = L10n.tr("Localizable", "CreateNewAlbum", fallback: "Create New Album")
  /// Creation Date: %@
  public static func creationDate(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Creation Date: %@", String(describing: p1), fallback: "Creation Date: %@")
  }
  /// Current Password
  public static let currentPassword = L10n.tr("Localizable", "Current Password", fallback: "Current Password")
  /// ./Encamera/ImageViewing/MovieViewing.swift
  public static let decrypting = L10n.tr("Localizable", "Decrypting...", fallback: "Decrypting...")
  /// Decryption error: %@. Please update the app to the latest version if you haven't already.
  public static func decryptionError(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Decryption error: %@", String(describing: p1), fallback: "Decryption error: %@. Please update the app to the latest version if you haven't already.")
  }
  /// ./EncameraCore/Constants/AppConstants.swift
  public static let defaultAlbumName = L10n.tr("Localizable", "DefaultAlbumName", fallback: "Default Album")
  /// Delete
  public static let delete = L10n.tr("Localizable", "Delete", fallback: "Delete")
  /// Delete Album?
  public static let deleteAlbumQuestion = L10n.tr("Localizable", "Delete Album question", fallback: "Delete Album?")
  /// Delete All Associated Data?
  public static let deleteAllAssociatedData = L10n.tr("Localizable", "Delete All Associated Data?", fallback: "Delete All Associated Data?")
  /// Delete Media & Key
  public static let deleteAllKeyData = L10n.tr("Localizable", "Delete All Key Data", fallback: "Delete Media & Key")
  /// Delete Everything
  public static let deleteEverything = L10n.tr("Localizable", "Delete Everything", fallback: "Delete Everything")
  /// ./Encamera/ImageViewing/GalleryHorizontalScrollView.swift
  public static let deleteThisImage = L10n.tr("Localizable", "Delete this image?", fallback: "Delete this image?")
  /// Delete Album
  public static let deleteAlbum = L10n.tr("Localizable", "DeleteAlbum", fallback: "Delete Album")
  /// Do you want to delete this album and all media associated with it forever?
  public static let deleteAlbumForever = L10n.tr("Localizable", "DeleteAlbumForever", fallback: "Do you want to delete this album and all media associated with it forever?")
  /// Delete Images?
  public static let deleteImported = L10n.tr("Localizable", "DeleteImported", fallback: "Delete Images?")
  /// Deletion Error
  public static let deletionError = L10n.tr("Localizable", "Deletion Error", fallback: "Deletion Error")
  /// Deselect All
  public static let deselectAll = L10n.tr("Localizable", "Deselect All", fallback: "Deselect All")
  /// Do you want to delete this key forever? All media will remain saved.
  public static let doYouWantToDeleteThisKeyForeverAllMediaWillRemainSaved = L10n.tr("Localizable", "Do you want to delete this key forever? All media will remain saved.", fallback: "Do you want to delete this key forever? All media will remain saved.")
  /// Done
  public static let done = L10n.tr("Localizable", "Done", fallback: "Done")
  /// Done!
  public static let doneOnboarding = L10n.tr("Localizable", "DoneOnboarding", fallback: "Done!")
  /// Do you remember your passcode?
  public static let doYouRememberYourPin = L10n.tr("Localizable", "DoYouRememberYourPin", fallback: "Do you remember your passcode?")
  /// If you don't, you can set a new one by going to 'Change Passcode'
  public static let doYouRememberYourPinSubtitle = L10n.tr("Localizable", "DoYouRememberYourPinSubtitle", fallback: "If you don't, you can set a new one by going to 'Change Passcode'")
  /// Are you done importing images?
  public static let doYouWantToDeleteNotImported = L10n.tr("Localizable", "DoYouWantToDeleteNotImported", fallback: "Are you done importing images?")
  /// Import Pictures
  public static let emptyAlbumImportPhotosActionTitle = L10n.tr("Localizable", "EmptyAlbumImportPhotosActionTitle", fallback: "Import Pictures")
  /// Secure your pics
  public static let emptyAlbumImportPhotosHeading = L10n.tr("Localizable", "EmptyAlbumImportPhotosHeading", fallback: "Secure your pics")
  /// Import pictures from your camera roll
  public static let emptyAlbumImportPhotosSubtitle = L10n.tr("Localizable", "EmptyAlbumImportPhotosSubtitle", fallback: "Import pictures from your camera roll")
  /// Take a picture
  public static let emptyAlbumTakeAPictureActionTitle = L10n.tr("Localizable", "EmptyAlbumTakeAPictureActionTitle", fallback: "Take a picture")
  /// Create a new memory
  public static let emptyAlbumTakeAPictureHeading = L10n.tr("Localizable", "EmptyAlbumTakeAPictureHeading", fallback: "Create a new memory")
  /// Open your camera and take a pic
  public static let emptyAlbumTakeAPictureSubtitle = L10n.tr("Localizable", "EmptyAlbumTakeAPictureSubtitle", fallback: "Open your camera and take a pic")
  /// Enable %@
  public static func enable(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Enable %@", String(describing: p1), fallback: "Enable %@")
  }
  /// Enable %@ to quickly and securely gain access to the app.
  public static func enableToQuicklyAndSecurelyGainAccessToTheApp(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Enable %@ to quickly and securely gain access to the app.", String(describing: p1), fallback: "Enable %@ to quickly and securely gain access to the app.")
  }
  /// Enable Face ID
  public static let enableFaceID = L10n.tr("Localizable", "Enable Face ID", fallback: "Enable Face ID")
  /// ./Encamera/Styles/ViewModifiers/ButtonViewModifier.swift
  public static let encryptEverything = L10n.tr("Localizable", "Encrypt Everything", fallback: "Encrypt Everything")
  /// Encrypting
  public static let encrypting = L10n.tr("Localizable", "Encrypting", fallback: "Encrypting")
  /// Encryption Key
  public static let encryptionKey = L10n.tr("Localizable", "Encryption Key", fallback: "Encryption Key")
  /// Enter Promo Code
  public static let enterPromoCode = L10n.tr("Localizable", "Enter Promo Code", fallback: "Enter Promo Code")
  /// Enter Key Phrase
  public static let enterKeyPhrase = L10n.tr("Localizable", "EnterKeyPhrase", fallback: "Enter Key Phrase")
  /// Enter the key phrase you want to import. Separate each word with a space.
  public static let enterKeyPhraseDescription = L10n.tr("Localizable", "EnterKeyPhraseDescription", fallback: "Enter the key phrase you want to import. Separate each word with a space.")
  /// Enter Passcode
  public static let enterPasscode = L10n.tr("Localizable", "EnterPasscode", fallback: "Enter Passcode")
  /// Enter your password
  public static let enterYourPassword = L10n.tr("Localizable", "EnterYourPassword", fallback: "Enter your password")
  /// Erase
  public static let erase = L10n.tr("Localizable", "Erase", fallback: "Erase")
  /// Erase All Data
  public static let eraseAllData = L10n.tr("Localizable", "Erase All Data", fallback: "Erase All Data")
  /// Erase App Data
  public static let eraseAppData = L10n.tr("Localizable", "Erase App Data", fallback: "Erase App Data")
  /// Erase Device Data
  public static let eraseDeviceData = L10n.tr("Localizable", "Erase Device Data", fallback: "Erase Device Data")
  /// Erase keychain data
  public static let eraseKeychainData = L10n.tr("Localizable", "Erase keychain data", fallback: "Erase keychain data")
  /// Erasing in %@
  public static func erasingIn(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Erasing in %@", String(describing: p1), fallback: "Erasing in %@")
  }
  /// Error clearing keychain
  public static let errorClearingKeychain = L10n.tr("Localizable", "Error clearing keychain", fallback: "Error clearing keychain")
  /// Error coding keychain data.
  public static let errorCodingKeychainData = L10n.tr("Localizable", "Error coding keychain data.", fallback: "Error coding keychain data.")
  /// Error deleting all files
  public static let errorDeletingAllFiles = L10n.tr("Localizable", "Error deleting all files", fallback: "Error deleting all files")
  /// ./Encamera/KeyManagement/KeyEntry.swift
  public static let errorSavingKey = L10n.tr("Localizable", "Error saving key", fallback: "Error saving key")
  /// Error importing key phrase
  public static let errorImportingKeyPhrase = L10n.tr("Localizable", "ErrorImportingKeyPhrase", fallback: "Error importing key phrase")
  /// Error saving password
  public static let errorSavingPassword = L10n.tr("Localizable", "ErrorSavingPassword", fallback: "Error saving password")
  /// Face ID
  public static let faceID = L10n.tr("Localizable", "Face ID", fallback: "Face ID")
  /// Failed to save password
  public static let failedToSavePassword = L10n.tr("Localizable", "FailedToSavePassword", fallback: "Failed to save password")
  /// ./Encamera/Styles/ViewModifiers/PurchaseOptionViewModifier.swift
  public static let familyShareable = L10n.tr("Localizable", "Family Shareable", fallback: "Family Shareable")
  /// Fast and convenient
  public static let fastAndConvenient = L10n.tr("Localizable", "Fast and convenient", fallback: "Fast and convenient")
  /// ./Encamera/Settings/SettingsView.swift
  public static let feedbackRequest = L10n.tr("Localizable", "FeedbackRequest", fallback: "Because Encamera does not track user behavior in any way, and collects no information about you, the user, we rely on your feedback to help us improve the app.")
  /// Let's secure some media
  public static let finishedOnboardingSubtitle = L10n.tr("Localizable", "FinishedOnboardingSubtitle", fallback: "Let's secure some media")
  /// You are ready to use Encamera!
  public static let finishedOnboardingTitle = L10n.tr("Localizable", "FinishedOnboardingTitle", fallback: "You are ready to use Encamera!")
  /// You are ready to use
  /// Encamera!
  public static let finishedReadyToUseEncamera = L10n.tr("Localizable", "FinishedReadyToUseEncamera", fallback: "You are ready to use\nEncamera!")
  /// Let's create your first album
  public static let finishedSubtitle = L10n.tr("Localizable", "FinishedSubtitle", fallback: "Let's create your first album")
  /// Finish Importing Media
  public static let finishImportingMedia = L10n.tr("Localizable", "FinishImportingMedia", fallback: "Finish Importing Media")
  /// Free Trial
  public static let freeTrial = L10n.tr("Localizable", "Free Trial", fallback: "Free Trial")
  /// 7 days free, then %@
  public static func freeTrialTerms(_ p1: Any) -> String {
    return L10n.tr("Localizable", "FreeTrialTerms", String(describing: p1), fallback: "7 days free, then %@")
  }
  /// Get Premium
  public static let getPremium = L10n.tr("Localizable", "GetPremium", fallback: "Get Premium")
  /// Let's Start
  public static let getStartedButtonText = L10n.tr("Localizable", "GetStartedButtonText", fallback: "Let's Start")
  /// ./Encamera/ImageViewing/GalleryGridView.swift
  public static let hide = L10n.tr("Localizable", "Hide", fallback: "Hide")
  /// ./Encamera/Settings/PromptToErase.swift
  public static let holdToErase = L10n.tr("Localizable", "Hold to erase", fallback: "Hold to erase")
  /// Hold to reveal
  public static let holdToReveal = L10n.tr("Localizable", "Hold to reveal", fallback: "Hold to reveal")
  /// I'm Done
  public static let iAmDone = L10n.tr("Localizable", "IAmDone", fallback: "I'm Done")
  /// ./EncameraCore/Models/StorageType.swift
  public static let iCloud = L10n.tr("Localizable", "iCloud", fallback: "iCloud")
  /// iCloud storage & backup
  public static let iCloudStorageFeatureRowTitle = L10n.tr("Localizable", "iCloudStorageFeatureRowTitle", fallback: "iCloud storage & backup")
  /// I Forgot
  public static let iForgot = L10n.tr("Localizable", "IForgot", fallback: "I Forgot")
  /// IMAGE SAVED TO ALBUM
  public static let imageSavedToAlbum = L10n.tr("Localizable", "ImageSavedToAlbum", fallback: "IMAGE SAVED TO ALBUM")
  /// Import
  public static let `import` = L10n.tr("Localizable", "Import", fallback: "Import")
  /// Import from Files
  public static let importFromFiles = L10n.tr("Localizable", "Import from files", fallback: "Import from Files")
  /// Import from Photos
  public static let importFromPhotos = L10n.tr("Localizable", "Import from photos", fallback: "Import from Photos")
  /// Importing... Please wait
  public static let importingPleaseWait = L10n.tr("Localizable", "ImportingPleaseWait", fallback: "Importing... Please wait")
  /// Import Key Phrase
  public static let importKeyPhrase = L10n.tr("Localizable", "ImportKeyPhrase", fallback: "Import Key Phrase")
  /// Import the selected images to your currently active key album
  public static let importSelectedImages = L10n.tr("Localizable", "ImportSelectedImages", fallback: "Import the selected images to your currently active key album")
  /// I'm Sure
  public static let imSure = L10n.tr("Localizable", "ImSure", fallback: "I'm Sure")
  /// Wrong PIN Code. Please try again.
  public static let incorrectPinCode = L10n.tr("Localizable", "IncorrectPinCode", fallback: "Wrong PIN Code. Please try again.")
  /// Add Encamera to your lock screen to quickly take pictures
  public static let installWidgetBody = L10n.tr("Localizable", "InstallWidgetBody", fallback: "Add Encamera to your lock screen to quickly take pictures")
  /// Add Widget
  public static let installWidgetButtonText = L10n.tr("Localizable", "InstallWidgetButtonText", fallback: "Add Widget")
  /// Install Lock Screen Widget
  public static let installWidgetTitle = L10n.tr("Localizable", "InstallWidgetTitle", fallback: "Install Lock Screen Widget")
  /// Invalid Password
  public static let invalidPassword = L10n.tr("Localizable", "Invalid Password", fallback: "Invalid Password")
  /// I Remember my Passcode
  public static let iRemember = L10n.tr("Localizable", "IRemember", fallback: "I Remember my Passcode")
  /// Join Discord
  public static let joinDiscord = L10n.tr("Localizable", "Join Discord", fallback: "Join Discord")
  /// Keep your encrypted data safe by using %@.
  public static func keepYourEncryptedDataSafeByUsing(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Keep your encrypted data safe by using %@.", String(describing: p1), fallback: "Keep your encrypted data safe by using %@.")
  }
  /// Key Entry
  public static let keyEntry = L10n.tr("Localizable", "Key Entry", fallback: "Key Entry")
  /// Key Info
  public static let keyInfo = L10n.tr("Localizable", "Key Info", fallback: "Key Info")
  /// Key length: %@
  public static func keyLength(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Key length: %@", String(describing: p1), fallback: "Key length: %@")
  }
  /// Key Management
  public static let keyManagement = L10n.tr("Localizable", "Key Management", fallback: "Key Management")
  /// Key name is invalid, must be more than two characters
  public static let keyNameIsInvalidMustBeMoreThanTwoCharacters = L10n.tr("Localizable", "Key name is invalid, must be more than two characters", fallback: "Key name is invalid, must be more than two characters")
  /// ./Encamera/KeyManagement/AddExchangedKeyConfirmation.swift
  public static func keyName(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Key Name: %@", String(describing: p1), fallback: "Key Name: %@")
  }
  /// Key not found.
  public static let keyNotFound = L10n.tr("Localizable", "Key not found.", fallback: "Key not found.")
  /// Keys
  public static let keys = L10n.tr("Localizable", "Keys", fallback: "Keys")
  /// Non explicabo officia aut odit ex eum ipsum libero.
  public static let keyTutorialText = L10n.tr("Localizable", "KeyTutorialText", fallback: "Non explicabo officia aut odit ex eum ipsum libero.")
  /// All of your files are encrypted
  public static let keyTutorialTitle = L10n.tr("Localizable", "KeyTutorialTitle", fallback: "All of your files are encrypted")
  /// Leave a Review
  public static let leaveAReview = L10n.tr("Localizable", "Leave a Review", fallback: "Leave a Review")
  /// Let's give your
  /// album a name
  public static let letsGiveYourAlbumAName = L10n.tr("Localizable", "LetsGiveYourAlbumAName", fallback: "Let's give your\nalbum a name")
  /// Let's go!
  public static let letsGo = L10n.tr("Localizable", "LetsGo", fallback: "Let's go!")
  /// Local
  public static let local = L10n.tr("Localizable", "Local", fallback: "Local")
  /// local device
  public static let localDevice = L10n.tr("Localizable", "LocalDevice", fallback: "local device")
  /// Choose how you want to access your private albums.
  public static let loginMethodDescription = L10n.tr("Localizable", "LoginMethodDescription", fallback: "Choose how you want to access your private albums.")
  /// Make sure you remember your pin code!
  public static let makeSureYouRememberYourPin = L10n.tr("Localizable", "MakeSureYouRememberYourPin", fallback: "Make sure you remember your pin code!")
  /// ./Encamera/CameraView/CameraView.swift
  public static let missingCameraAccess = L10n.tr("Localizable", "Missing camera access", fallback: "Missing camera access")
  /// ./Encamera/AuthenticationView/AuthenticationView.swift
  public static let missingPassword = L10n.tr("Localizable", "Missing password", fallback: "Missing password")
  /// Upgrade to premium to unlock unlimited photos
  public static let modalUpgradeText = L10n.tr("Localizable", "ModalUpgradeText", fallback: "Upgrade to premium to unlock unlimited photos")
  /// MOST POPULAR
  public static let mostPopular = L10n.tr("Localizable", "MostPopular", fallback: "MOST POPULAR")
  /// Change Storage
  public static let moveAlbumStorage = L10n.tr("Localizable", "MoveAlbumStorage", fallback: "Change Storage")
  /// Could not load or decrypt movie. It may not be able to be downloaded. If this media is on iCloud, make sure you are able to download files with your current Internet connection. Error: %@. Please update the app to the latest version if you haven't already.
  public static func movieDecryptionError(_ p1: Any) -> String {
    return L10n.tr("Localizable", "MovieDecryptionError", String(describing: p1), fallback: "Could not load or decrypt movie. It may not be able to be downloaded. If this media is on iCloud, make sure you are able to download files with your current Internet connection. Error: %@. Please update the app to the latest version if you haven't already.")
  }
  /// You can have multiple keys for different purposes, e.g. one named "Documents" and another "Personal".
  public static let multipleKeysForMultiplePurposesExplanation = L10n.tr("Localizable", "MultipleKeysForMultiplePurposesExplanation", fallback: "You can have multiple keys for different purposes, e.g. one named \"Documents\" and another \"Personal\".")
  /// New Album
  public static let newAlbum = L10n.tr("Localizable", "New Album", fallback: "New Album")
  /// Set the name for this encrypted photo album.
  public static let newAlbumSubheading = L10n.tr("Localizable", "New Album Subheading", fallback: "Set the name for this encrypted photo album.")
  /// New Password
  public static let newPassword = L10n.tr("Localizable", "New Password", fallback: "New Password")
  /// ./Encamera/Onboarding/MainOnboardingView.swift
  public static let next = L10n.tr("Localizable", "Next", fallback: "Next")
  /// No
  public static let no = L10n.tr("Localizable", "No", fallback: "No")
  /// No file access available.
  public static let noFileAccessAvailable = L10n.tr("Localizable", "No file access available.", fallback: "No file access available.")
  /// ./EncameraCore/Utils/DataStorageUserDefaultsSetting.swift
  public static let noICloudAccountFoundOnThisDevice = L10n.tr("Localizable", "No iCloud account found on this device.", fallback: "No iCloud account found on this device.")
  /// ./Encamera/ImageViewing/PhotoInfoView.swift
  public static let noInfoAvailable = L10n.tr("Localizable", "No info available", fallback: "No info available")
  /// ./Encamera/ImageViewing/ImageViewing.swift
  public static let noKeyAvailable = L10n.tr("Localizable", "No key available.", fallback: "No key available.")
  /// ./Encamera/EncameraApp.swift
  public static let noPrivateKeyOrMediaFound = L10n.tr("Localizable", "No private key or media found.", fallback: "No private key or media found.")
  /// No Album
  public static let noAlbum = L10n.tr("Localizable", "NoAlbum", fallback: "No Album")
  /// No Album Selected. You must select an album to save photos to.
  public static let noAlbumSelected = L10n.tr("Localizable", "NoAlbumSelected", fallback: "No Album Selected. You must select an album to save photos to.")
  /// No commitment, cancel anytime
  public static let noCommitmentCancelAnytime = L10n.tr("Localizable", "NoCommitmentCancelAnytime", fallback: "No commitment, cancel anytime")
  /// None
  public static let `none` = L10n.tr("Localizable", "None", fallback: "None")
  /// Not authenticated for this operation.
  public static let notAuthenticatedForThisOperation = L10n.tr("Localizable", "Not authenticated for this operation.", fallback: "Not authenticated for this operation.")
  /// ./EncameraCore/Utils/PasswordValidator.swift
  public static let notDetermined = L10n.tr("Localizable", "Not determined.", fallback: "Not determined.")
  /// I'm Not Done
  public static let notDoneYet = L10n.tr("Localizable", "NotDoneYet", fallback: "I'm Not Done")
  /// All media is encrypted before saving. Nobody can view your files except you.
  public static let notificationBannerBody = L10n.tr("Localizable", "NotificationBannerBody", fallback: "All media is encrypted before saving. Nobody can view your files except you.")
  /// Notification Banners
  public static let notificationBannerTitle = L10n.tr("Localizable", "NotificationBannerTitle", fallback: "Secured with Encryption")
  /// Notifications
  public static let notificationListTitle = L10n.tr("Localizable", "NotificationListTitle", fallback: "Notifications")
  /// OK
  public static let ok = L10n.tr("Localizable", "OK", fallback: "OK")
  /// Camera access
  public static let onboardingPermissionsCameraAccess = L10n.tr("Localizable", "OnboardingPermissionsCameraAccess", fallback: "Camera access")
  /// Needed to take photos
  public static let onboardingPermissionsCameraAccessSubheading = L10n.tr("Localizable", "OnboardingPermissionsCameraAccessSubheading", fallback: "Needed to take photos")
  /// Microphone access
  public static let onboardingPermissionsMicrophoneAccess = L10n.tr("Localizable", "OnboardingPermissionsMicrophoneAccess", fallback: "Microphone access")
  /// Needed only for videos
  public static let onboardingPermissionsMicrophoneAccessSubheading = L10n.tr("Localizable", "OnboardingPermissionsMicrophoneAccessSubheading", fallback: "Needed only for videos")
  /// You will need to give permissions to use the camera & microphone in order to access the app
  public static let onboardingPermissionsSubheading = L10n.tr("Localizable", "OnboardingPermissionsSubheading", fallback: "You will need to give permissions to use the camera & microphone in order to access the app")
  /// Permissions
  public static let onboardingPermissionsTitle = L10n.tr("Localizable", "OnboardingPermissionsTitle", fallback: "Permissions")
  /// One-Time Purchase
  public static let oneTimePurchase = L10n.tr("Localizable", "One-Time Purchase", fallback: "One-Time Purchase")
  /// Open Source
  public static let openSource = L10n.tr("Localizable", "Open Source", fallback: "Open Source")
  /// Open Settings
  public static let openSettings = L10n.tr("Localizable", "OpenSettings", fallback: "Open Settings")
  /// Go to Settings
  public static let openSystemSettings = L10n.tr("Localizable", "OpenSystemSettings", fallback: "Go to Settings")
  /// Or
  public static let or = L10n.tr("Localizable", "Or", fallback: "Or")
  /// Are you sure you want to overwrite your current key phrase? You will not be able to access any media encrypted with the current key phrase.
  public static let overwriteAreYouSure = L10n.tr("Localizable", "OverwriteAreYouSure", fallback: "Are you sure you want to overwrite your current key phrase? You will not be able to access any media encrypted with the current key phrase.")
  /// Overwrite Key Phrase?
  public static let overwriteKeyPhrase = L10n.tr("Localizable", "OverwriteKeyPhrase", fallback: "Overwrite Key Phrase?")
  /// Password
  public static let password = L10n.tr("Localizable", "Password", fallback: "Password")
  /// Password incorrect
  public static let passwordIncorrect = L10n.tr("Localizable", "Password incorrect", fallback: "Password incorrect")
  /// Password is too long, >%@
  public static func passwordIsTooLong(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Password is too long, >%@", String(describing: p1), fallback: "Password is too long, >%@")
  }
  /// Password is too short, <%@
  public static func passwordIsTooShort(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Password is too short, <%@", String(describing: p1), fallback: "Password is too short, <%@")
  }
  /// Password is valid.
  public static let passwordIsValid = L10n.tr("Localizable", "Password is valid.", fallback: "Password is valid.")
  /// Password successfully changed
  public static let passwordSuccessfullyChanged = L10n.tr("Localizable", "Password successfully changed", fallback: "Password successfully changed")
  /// Passwords do not match
  public static let passwordMismatch = L10n.tr("Localizable", "PasswordMismatch", fallback: "Passwords do not match")
  /// Passwords do not match.
  public static let passwordsDoNotMatch = L10n.tr("Localizable", "Passwords do not match.", fallback: "Passwords do not match.")
  /// Password Set Successfully
  public static let passwordSetSuccessfully = L10n.tr("Localizable", "PasswordSetSuccessfully", fallback: "Password Set Successfully")
  /// Your new password has been saved
  public static let passwordSetSuccessMessage = L10n.tr("Localizable", "PasswordSetSuccessMessage", fallback: "Your new password has been saved")
  /// Paste the private key here.
  public static let pasteThePrivateKeyHere = L10n.tr("Localizable", "Paste the private key here.", fallback: "Paste the private key here.")
  /// You must enable camera permissions to continue. Open the settings app to do this.
  public static let permissionsNeededText = L10n.tr("Localizable", "PermissionsNeededText", fallback: "You must enable camera permissions to continue. Open the settings app to do this.")
  /// Camera Permissions Needed
  public static let permissionsNeededTitle = L10n.tr("Localizable", "PermissionsNeededTitle", fallback: "Camera Permissions Needed")
  /// ./Encamera/CameraView/CameraModePicker.swift
  public static let photo = L10n.tr("Localizable", "PHOTO", fallback: "PHOTO")
  /// Photo limit reached
  public static let photoLimitReached = L10n.tr("Localizable", "Photo limit reached", fallback: "Photo limit reached")
  /// PIN doesn't match. Please try again.
  public static let pinCodeDoesNotMatch = L10n.tr("Localizable", "PinCodeDoesNotMatch", fallback: "PIN doesn't match. Please try again.")
  /// Too many attempts. Please wait for %@
  public static func pinCodeLockTryAgainIn(_ p1: Any) -> String {
    return L10n.tr("Localizable", "PinCodeLockTryAgainIn", String(describing: p1), fallback: "Too many attempts. Please wait for %@")
  }
  /// Pincodes are not the same
  public static let pinCodeMismatch = L10n.tr("Localizable", "PinCodeMismatch", fallback: "Pincodes are not the same")
  /// Pin successfully changed
  public static let pinSuccessfullyChanged = L10n.tr("Localizable", "PinSuccessfullyChanged", fallback: "Pin successfully changed")
  /// PIN is too short. It must be at least %@ digits.
  public static func pinTooShort(_ p1: Any) -> String {
    return L10n.tr("Localizable", "PinTooShort", String(describing: p1), fallback: "PIN is too short. It must be at least %@ digits.")
  }
  /// Please select a storage location.
  public static let pleaseSelectAStorageLocation = L10n.tr("Localizable", "Please select a storage location.", fallback: "Please select a storage location.")
  /// Please enter a name for the album
  public static let pleaseEnterAnAlbumName = L10n.tr("Localizable", "PleaseEnterAnAlbumName", fallback: "Please enter a name for the album")
  /// premium
  public static let premium = L10n.tr("Localizable", "premium", fallback: "premium")
  /// Unlimited albums and iCloud storage
  public static let premiumUnlockTheseBenefits = L10n.tr("Localizable", "PremiumUnlockTheseBenefits", fallback: "Unlimited albums and iCloud storage")
  /// Privacy Policy
  public static let privacyPolicy = L10n.tr("Localizable", "Privacy Policy", fallback: "Privacy Policy")
  /// ./Encamera/Onboarding/OnboardingView.swift
  public static let profileSetup = L10n.tr("Localizable", "ProfileSetup", fallback: "PROFILE SETUP")
  /// 60 days free, then %@
  public static func promoFreeTrialTerms(_ p1: Any) -> String {
    return L10n.tr("Localizable", "PromoFreeTrialTerms", String(describing: p1), fallback: "60 days free, then %@")
  }
  /// Unlimited albums and iCloud storage
  ///  and TWO MONTHS FREE
  public static let promoPremiumUnlockTheseBenefits = L10n.tr("Localizable", "PromoPremiumUnlockTheseBenefits", fallback: "Unlimited albums and iCloud storage\n and TWO MONTHS FREE")
  /// Purchase
  public static let purchaseProduct = L10n.tr("Localizable", "PurchaseProduct", fallback: "Purchase")
  /// Widget
  public static let quicklyTakePictures = L10n.tr("Localizable", "QuicklyTakePictures", fallback: "Quickly take pictures and video.")
  /// Recovery Phrase Copied!
  public static let recoveryPhraseCopied = L10n.tr("Localizable", "RecoveryPhraseCopied", fallback: "Recovery Phrase Copied!")
  /// This will remove your passcode. You will only be able to use Face ID to get into the app. Continue?
  public static let removePasscode = L10n.tr("Localizable", "RemovePasscode", fallback: "This will remove your passcode. You will only be able to use Face ID to get into the app. Continue?")
  /// Rename
  public static let rename = L10n.tr("Localizable", "Rename", fallback: "Rename")
  /// Repeat Password
  public static let repeatPassword = L10n.tr("Localizable", "RepeatPassword", fallback: "Repeat Password")
  /// Repeat your password to confirm.
  public static let repeatPasswordSubtitle = L10n.tr("Localizable", "repeatPasswordSubtitle", fallback: "Repeat your password to confirm.")
  /// Repeat Pin Code
  public static let repeatPinCode = L10n.tr("Localizable", "RepeatPinCode", fallback: "Repeat Pin Code")
  /// Repeat your Pin code to confirm.
  public static let repeatPinCodeSubtitle = L10n.tr("Localizable", "RepeatPinCodeSubtitle", fallback: "Repeat your Pin code to confirm.")
  /// Restore Purchases
  public static let restorePurchases = L10n.tr("Localizable", "Restore Purchases", fallback: "Restore Purchases")
  /// Roadmap & Feature Requests
  public static let roadmap = L10n.tr("Localizable", "Roadmap", fallback: "Roadmap & Feature Requests")
  /// Save
  public static let save = L10n.tr("Localizable", "Save", fallback: "Save")
  /// Save Key
  public static let saveKey = L10n.tr("Localizable", "Save Key", fallback: "Save Key")
  /// Save Key to iCloud
  public static let saveKeyToICloud = L10n.tr("Localizable", "Save Key to iCloud", fallback: "Save Key to iCloud")
  /// Save this media?
  public static let saveThisMedia = L10n.tr("Localizable", "Save this media?", fallback: "Save this media?")
  /// SAVE %@
  public static func saveAmount(_ p1: Any) -> String {
    return L10n.tr("Localizable", "SaveAmount %@ $@", String(describing: p1), fallback: "SAVE %@")
  }
  /// Saved to Device
  public static let savedToDevice = L10n.tr("Localizable", "Saved to Device", fallback: "Saved to Device")
  /// Saved to iCloud
  public static let savedToICloud = L10n.tr("Localizable", "Saved to iCloud", fallback: "Saved to iCloud")
  /// Save to this device
  public static let saveLocally = L10n.tr("Localizable", "SaveLocally", fallback: "Save to this device")
  /// SAVE %@
  public static func savePercent(_ p1: Any) -> String {
    return L10n.tr("Localizable", "SavePercent %@", String(describing: p1), fallback: "SAVE %@")
  }
  /// Save PIN Code
  public static let savePinCode = L10n.tr("Localizable", "SavePinCode", fallback: "Save PIN Code")
  /// Save to iCloud Drive
  public static let saveToiCloudDrive = L10n.tr("Localizable", "SaveToiCloudDrive", fallback: "Save to iCloud Drive")
  /// Scan with Encamera app
  public static let scanWithEncameraApp = L10n.tr("Localizable", "Scan with Encamera app", fallback: "Scan with Encamera app")
  /// See the photos that belong to a key by tapping the 
  public static let seeThePhotosThatBelongToAKeyByTappingThe = L10n.tr("Localizable", "See the photos that belong to a key by tapping the ", fallback: "See the photos that belong to a key by tapping the ")
  /// Select a place to keep media for this key.
  public static let selectAPlaceToKeepMediaForThisKey = L10n.tr("Localizable", "Select a place to keep media for this key.", fallback: "Select a place to keep media for this key.")
  /// ./Encamera/MediaImport/MediaImportView.swift
  public static let selectAll = L10n.tr("Localizable", "Select All", fallback: "Select All")
  /// Please select a method
  public static let selectLoginMethod = L10n.tr("Localizable", "Select Login Method", fallback: "Please select a method")
  /// Select Storage
  public static let selectStorage = L10n.tr("Localizable", "Select Storage", fallback: "Select Storage")
  /// Select an Option
  public static let selectAnOption = L10n.tr("Localizable", "SelectAnOption", fallback: "Select an Option")
  /// Select a Product
  public static let selectProduct = L10n.tr("Localizable", "SelectProduct", fallback: "Select a Product")
  /// PIN Code Setting
  public static let set6DigitPIN = L10n.tr("Localizable", "Set 6-Digit PIN", fallback: "Set 6-Digit PIN")
  /// Set as Active Key
  public static let setAsActiveKey = L10n.tr("Localizable", "Set as Active Key", fallback: "Set as Active Key")
  /// Set Password
  public static let setPassword = L10n.tr("Localizable", "Set Password", fallback: "Set Password")
  /// Set a password to access the app. Be sure to store it in a safe place – you cannot recover it later.
  public static let setAPasswordWarning = L10n.tr("Localizable", "SetAPasswordWarning", fallback: "Set a password to access the app. Be sure to store it in a safe place – you cannot recover it later.")
  /// This password will be used to securely access the app. Make sure you remember it!
  public static let setPasswordSubtitle = L10n.tr("Localizable", "setPasswordSubtitle", fallback: "This password will be used to securely access the app. Make sure you remember it!")
  /// Set Pin Code
  public static let setPinCode = L10n.tr("Localizable", "SetPinCode", fallback: "Set Pin Code")
  /// This pin will be used to securely access the app. Make sure you remember it!
  public static let setPinCodeSubtitle = L10n.tr("Localizable", "SetPinCodeSubtitle", fallback: "This pin will be used to securely access the app. Make sure you remember it!")
  /// Settings
  public static let settings = L10n.tr("Localizable", "Settings", fallback: "Settings")
  /// Face ID is Disabled
  public static let settingsFaceIdDisabled = L10n.tr("Localizable", "SettingsFaceIdDisabled", fallback: "Face ID is Disabled")
  /// You have disabled Face ID for Encamera. Enable it in Settings to login with Face ID.
  public static let settingsFaceIdOpenSettings = L10n.tr("Localizable", "SettingsFaceIdOpenSettings", fallback: "You have disabled Face ID for Encamera. Enable it in Settings to login with Face ID.")
  /// Share
  public static let share = L10n.tr("Localizable", "Share", fallback: "Share")
  /// Share Decrypted
  public static let shareDecrypted = L10n.tr("Localizable", "Share Decrypted", fallback: "Share Decrypted")
  /// Share Encrypted
  public static let shareEncrypted = L10n.tr("Localizable", "Share Encrypted", fallback: "Share Encrypted")
  /// Share Image
  public static let shareImage = L10n.tr("Localizable", "Share Image", fallback: "Share Image")
  /// Share Key
  public static let shareKey = L10n.tr("Localizable", "Share Key", fallback: "Share Key")
  /// Share this image?
  public static let shareThisImage = L10n.tr("Localizable", "Share this image?", fallback: "Share this image?")
  /// ./Encamera/ShareHandling/ShareHandling.swift
  public static let sharedMedia = L10n.tr("Localizable", "Shared Media", fallback: "Shared Media")
  /// ./Encamera/KeyManagement/KeyExchange.swift
  public static let shareKeyExplanation = L10n.tr("Localizable", "ShareKeyExplanation", fallback: "Share your encryption key with someone you trust.\n\nSharing it with them means they can decrypt any media you share with them that is encrypted with this key.")
  /// Skip for now
  public static let skipForNow = L10n.tr("Localizable", "Skip for now", fallback: "Skip for now")
  /// ./Encamera/Store/PurchaseUpgradeView.swift
  public static let startTrialOffer = L10n.tr("Localizable", "Start trial offer", fallback: "Start free trial")
  /// Where do you want to store your media? Each key will store data in its own directory once encrypted.
  public static let storageLocationOnboarding = L10n.tr("Localizable", "Storage location onboarding", fallback: "Where do you want to store your media? Each key will store data in its own directory once encrypted.")
  /// Storage Settings
  public static let storageSettings = L10n.tr("Localizable", "Storage Settings", fallback: "Storage Settings")
  /// Encamera does not store media to your camera roll. All encrypted media are stored either on this app or on iCloud, depending on your storage choice.
  public static let storageExplanation = L10n.tr("Localizable", "StorageExplanation", fallback: "Encamera does not store media to your camera roll. All encrypted media are stored either on this app or on iCloud, depending on your storage choice.")
  /// Where are my photos stored?
  public static let storageExplanationHeader = L10n.tr("Localizable", "StorageExplanationHeader", fallback: "Where are my photos stored?")
  /// Where do you want to store media for files encrypted with this key?
  /// Each key will store data in its own directory.
  /// 
  public static let storageSettingsSubheading = L10n.tr("Localizable", "StorageSettingsSubheading", fallback: "Where do you want to store media for files encrypted with this key?\nEach key will store data in its own directory.\n")
  /// Subscribe
  public static let subscribe = L10n.tr("Localizable", "Subscribe", fallback: "Subscribe")
  /// ./Encamera/Store/SubscriptionOptionView.swift
  public static let subscribed = L10n.tr("Localizable", "Subscribed", fallback: "Subscribed")
  /// Subscription
  public static let subscription = L10n.tr("Localizable", "Subscription", fallback: "Subscription")
  /// Support privacy-focused development.
  public static let supportPrivacyFocusedDevelopment = L10n.tr("Localizable", "Support privacy-focused development.", fallback: "Support privacy-focused development.")
  /// Take a Photo!
  public static let takeAPhoto = L10n.tr("Localizable", "Take a Photo!", fallback: "Take a Photo!")
  /// Take another photo
  public static let takeAnotherPhoto = L10n.tr("Localizable", "TakeAnotherPhoto", fallback: "Take another photo")
  /// Give us your feedback and get 3 months for free
  public static let takeSurveyBody = L10n.tr("Localizable", "TakeSurveyBody", fallback: "Give us your feedback and get 3 months for free")
  /// Take Survey
  public static let takeSurveyButtonText = L10n.tr("Localizable", "TakeSurveyButtonText", fallback: "Take Survey")
  /// Want 3 Months Free?
  public static let takeSurveyTitle = L10n.tr("Localizable", "TakeSurveyTitle", fallback: "Want 3 Months Free?")
  /// TAKE YOUR FIRST PICTURE
  public static let takeYourFirstPicture = L10n.tr("Localizable", "TakeYourFirstPicture", fallback: "TAKE YOUR FIRST PICTURE")
  /// Tap the 
  public static let tapThe = L10n.tr("Localizable", "Tap the ", fallback: "Tap the ")
  /// Tap to Upgrade
  public static let tapToUpgrade = L10n.tr("Localizable", "Tap to Upgrade", fallback: "Tap to Upgrade")
  /// Get early access to beta features and give feedback
  public static let telegramGroupJoinBody = L10n.tr("Localizable", "TelegramGroupJoinBody", fallback: "Get early access to beta features and give feedback")
  /// Join Group
  public static let telegramGroupJoinButtonText = L10n.tr("Localizable", "TelegramGroupJoinButtonText", fallback: "Join Group")
  /// Join Telegram Group
  public static let telegramGroupJoinTitle = L10n.tr("Localizable", "TelegramGroupJoinTitle", fallback: "Join Telegram Group")
  /// Terms of Use
  public static let termsOfUse = L10n.tr("Localizable", "Terms of Use", fallback: "Terms of Use")
  /// Here is a test of the string translation
  public static let test = L10n.tr("Localizable", "Test", fallback: "Here is a test of the string translation")
  /// Thank you for your support!
  public static let thankYouForYourSupport = L10n.tr("Localizable", "Thank you for your support!", fallback: "Thank you for your support!")
  /// Thanks for purchasing a lifetime license!
  public static let thanksForPurchasingLifetime = L10n.tr("Localizable", "ThanksForPurchasingLifetime", fallback: "Thanks for purchasing a lifetime license!")
  /// You rock and you will unlock new benefits soon.
  public static let thanksForPurchasingLifetimeSubtitle = L10n.tr("Localizable", "ThanksForPurchasingLifetimeSubtitle", fallback: "You rock and you will unlock new benefits soon.")
  /// ./Encamera/ImageViewing/DecryptErrorExplanation.swift
  public static let theMediaYouTriedToOpenCouldNotBeDecrypted = L10n.tr("Localizable", "The media you tried to open could not be decrypted.", fallback: "The media you tried to open could not be decrypted.")
  /// This will save the media to your library.
  public static let thisWillSaveTheMediaToYourLibrary = L10n.tr("Localizable", "This will save the media to your library.", fallback: "This will save the media to your library.")
  /// ./EncameraCore/Utils/AuthManager.swift
  public static let touchID = L10n.tr("Localizable", "Touch ID", fallback: "Touch ID")
  /// Try Again
  public static let tryAgain = L10n.tr("Localizable", "TryAgain", fallback: "Try Again")
  /// Unlimited albums for your memories
  public static let unlimitedAlbumsFeatureRowTitle = L10n.tr("Localizable", "UnlimitedAlbumsFeatureRowTitle", fallback: "Unlimited albums for your memories")
  /// ./Encamera/Store/SubscriptionView.swift
  public static let unlimitedStorageFeatureRowTitle = L10n.tr("Localizable", "UnlimitedStorageFeatureRowTitle", fallback: "Unlimited storage for photos & videos")
  /// Unlock
  public static let unlock = L10n.tr("Localizable", "Unlock", fallback: "Unlock")
  /// Unlock with %@
  public static func unlockWith(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Unlock with %@", String(describing: p1), fallback: "Unlock with %@")
  }
  /// Unlock Unlimited for Free!
  public static let unlockUnlimitedForFree = L10n.tr("Localizable", "UnlockUnlimitedForFree", fallback: "Unlock Unlimited for Free!")
  /// Unlock
  public static let unlockWithPin = L10n.tr("Localizable", "UnlockWithPin", fallback: "Unlock")
  /// Upgrade to Premium
  public static let upgradeToPremium = L10n.tr("Localizable", "Upgrade to Premium", fallback: "Upgrade to Premium")
  /// ./Encamera/InAppPurchase/PurchasePhotoSubscriptionOverlay.swift
  public static let upgradeToViewUnlimitedPhotos = L10n.tr("Localizable", "Upgrade to view unlimited photos", fallback: "Upgrade to view unlimited photos")
  /// Upgrade Today!
  public static let upgradeToday = L10n.tr("Localizable", "Upgrade Today!", fallback: "Upgrade Today!")
  /// Use %@?
  public static func use(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Use %@?", String(describing: p1), fallback: "Use %@?")
  }
  /// Face ID
  public static let useFaceID = L10n.tr("Localizable", "Use Face ID", fallback: "Use Face ID")
  /// Use Passcode instead
  public static let usePasscodeInstead = L10n.tr("Localizable", "Use Passcode instead", fallback: "Use Passcode instead")
  /// Use Password
  public static let usePassword = L10n.tr("Localizable", "Use Password", fallback: "Use Password")
  /// Use the built-in camera to take photos and videos.
  public static let useCameraToTakePhotos = L10n.tr("Localizable", "UseCameraToTakePhotos", fallback: "Use the built-in camera to take photos and videos.")
  /// VIDEO
  public static let video = L10n.tr("Localizable", "VIDEO", fallback: "VIDEO")
  /// View unlimited photos for each key.
  public static let viewUnlimitedPhotosForEachKey = L10n.tr("Localizable", "View unlimited photos for each key.", fallback: "View unlimited photos for each key.")
  /// View Albums
  public static let viewAlbums = L10n.tr("Localizable", "ViewAlbums", fallback: "View Albums")
  /// View in Files App
  public static let viewInFiles = L10n.tr("Localizable", "ViewInFiles", fallback: "View in Files App")
  /// ./Encamera/AuthenticationView/PasswordEntry.swift
  public static let welcomeBack = L10n.tr("Localizable", "WelcomeBack", fallback: "Welcome back!")
  /// What is Encamera?
  public static let whatIsEncamera = L10n.tr("Localizable", "What is Encamera?", fallback: "What is Encamera?")
  /// Where do you want to save this key's media?
  public static let whereDoYouWantToSaveThisKeySMedia = L10n.tr("Localizable", "Where do you want to save this key's media?", fallback: "Where do you want to save this key's media?")
  /// You will find all of your photos and videos grouped in the "Albums"
  public static let whereToFindYourPictures = L10n.tr("Localizable", "WhereToFindYourPictures", fallback: "You will find all of your photos and videos grouped in the \"Albums\"")
  /// Why Encrypt Media?
  public static let whyEncryptMedia = L10n.tr("Localizable", "Why Encrypt Media?", fallback: "Why Encrypt Media?")
  /// Yes
  public static let yes = L10n.tr("Localizable", "Yes", fallback: "Yes")
  /// You have an existing password for this device.
  public static let youHaveAnExistingPasswordForThisDevice = L10n.tr("Localizable", "You have an existing password for this device.", fallback: "You have an existing password for this device.")
  /// You took your first photo! 📸 🥳
  public static let youTookYourFirstPhoto📸🥳 = L10n.tr("Localizable", "You took your first photo! 📸 🥳", fallback: "You took your first photo! 📸 🥳")
  /// Your Keys
  public static let yourKeys = L10n.tr("Localizable", "Your Keys", fallback: "Your Keys")
  /// Key Backup
  public static let yourRecoveryPhrase = L10n.tr("Localizable", "YourRecoveryPhrase", fallback: "Key Backup")
  public enum AddAlbumModal {
    /// Let's rename your
    /// album
    public static let renameAlbumTitle = L10n.tr("Localizable", "AddAlbumModal.RenameAlbumTitle", fallback: "Let's rename your\nalbum")
  }
  public enum AlbumDetailView {
    /// Add your first image
    public static let addFirstImage = L10n.tr("Localizable", "AlbumDetailView.AddFirstImage", fallback: "Add your first image")
    /// Import an image from your album or open the camera and take a new picture for this album
    public static let addFirstImageSubtitle = L10n.tr("Localizable", "AlbumDetailView.AddFirstImageSubtitle", fallback: "Import an image from your album or open the camera and take a new picture for this album")
    /// Album Cover
    public static let albumCoverMenuTitle = L10n.tr("Localizable", "AlbumDetailView.AlbumCoverMenuTitle", fallback: "Album Cover")
    /// Album is now hidden
    public static let albumHiddenToast = L10n.tr("Localizable", "AlbumDetailView.AlbumHiddenToast", fallback: "Album is now hidden")
    /// Album is now visible
    public static let albumUnhiddenToast = L10n.tr("Localizable", "AlbumDetailView.AlbumUnhiddenToast", fallback: "Album is now visible")
    /// Capture
    public static let captureButton = L10n.tr("Localizable", "AlbumDetailView.CaptureButton", fallback: "Capture")
    /// Take photo
    public static let captureButtonAccessibilityLabel = L10n.tr("Localizable", "AlbumDetailView.CaptureButtonAccessibilityLabel", fallback: "Take photo")
    /// Clear Filters
    public static let clearFilters = L10n.tr("Localizable", "AlbumDetailView.ClearFilters", fallback: "Clear Filters")
    /// Confirm Delete
    public static let confirmDeletion = L10n.tr("Localizable", "AlbumDetailView.ConfirmDeletion", fallback: "Confirm Delete")
    /// Cover image disabled
    public static let coverImageRemovedToast = L10n.tr("Localizable", "AlbumDetailView.CoverImageRemovedToast", fallback: "Cover image disabled")
    /// Cover image defaults to latest image
    public static let coverImageResetToast = L10n.tr("Localizable", "AlbumDetailView.CoverImageResetToast", fallback: "Cover image defaults to latest image")
    /// Do you want to delete %@ %@?
    public static func deleteSelectedMedia(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.DeleteSelectedMedia", String(describing: p1), String(describing: p2), fallback: "Do you want to delete %@ %@?")
    }
    /// Disable Cover
    public static let disableCover = L10n.tr("Localizable", "AlbumDetailView.DisableCover", fallback: "Disable Cover")
    /// Enable Cover
    public static let enableCover = L10n.tr("Localizable", "AlbumDetailView.EnableCover", fallback: "Enable Cover")
    /// Plural format key: "%#@file_count@ on %2$@"
    public static func fileCountOnLocation(_ p1: Int, _ p2: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.FileCountOnLocation", p1, String(describing: p2), fallback: "Plural format key: \"%#@file_count@ on %2$@\"")
    }
    /// Filter
    public static let filterButton = L10n.tr("Localizable", "AlbumDetailView.FilterButton", fallback: "Filter")
    /// Sort and filter
    public static let filterButtonAccessibilityLabel = L10n.tr("Localizable", "AlbumDetailView.FilterButtonAccessibilityLabel", fallback: "Sort and filter")
    /// Are you sure you want to hide this album? You MUST remember the name of this album to access it again.
    public static let hideAlbumAlertMessage = L10n.tr("Localizable", "AlbumDetailView.HideAlbumAlertMessage", fallback: "Are you sure you want to hide this album? You MUST remember the name of this album to access it again.")
    /// Hide this album?
    public static let hideAlbumAlertTitle = L10n.tr("Localizable", "AlbumDetailView.HideAlbumAlertTitle", fallback: "Hide this album?")
    /// Hide Album
    public static let hideAlbumMenuItem = L10n.tr("Localizable", "AlbumDetailView.HideAlbumMenuItem", fallback: "Hide Album")
    /// Hide
    public static let hideAlbumRowTitle = L10n.tr("Localizable", "AlbumDetailView.HideAlbumRowTitle", fallback: "Hide")
    /// Import Pictures
    public static let importButton = L10n.tr("Localizable", "AlbumDetailView.ImportButton", fallback: "Import Pictures")
    /// None of the selected files could be imported (%@).
    public static func importFailedAlertMessage(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.ImportFailedAlertMessage", String(describing: p1), fallback: "None of the selected files could be imported (%@).")
    }
    /// Import Failed
    public static let importFailedAlertTitle = L10n.tr("Localizable", "AlbumDetailView.ImportFailedAlertTitle", fallback: "Import Failed")
    /// Imported %@ of %@ files. %@ skipped (%@).
    public static func importPartialSkipToast(_ p1: Any, _ p2: Any, _ p3: Any, _ p4: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.ImportPartialSkipToast", String(describing: p1), String(describing: p2), String(describing: p3), String(describing: p4), fallback: "Imported %@ of %@ files. %@ skipped (%@).")
    }
    /// could not be downloaded from iCloud
    public static let importReasonAssetDownloadFailed = L10n.tr("Localizable", "AlbumDetailView.ImportReasonAssetDownloadFailed", fallback: "could not be downloaded from iCloud")
    /// no longer shared with Encamera
    public static let importReasonAssetNoLongerShared = L10n.tr("Localizable", "AlbumDetailView.ImportReasonAssetNoLongerShared", fallback: "no longer shared with Encamera")
    /// file could not be read
    public static let importReasonReadError = L10n.tr("Localizable", "AlbumDetailView.ImportReasonReadError", fallback: "file could not be read")
    /// could not be converted
    public static let importReasonTranscodeFailed = L10n.tr("Localizable", "AlbumDetailView.ImportReasonTranscodeFailed", fallback: "could not be converted")
    /// unsupported format
    public static let importReasonUnsupportedFormat = L10n.tr("Localizable", "AlbumDetailView.ImportReasonUnsupportedFormat", fallback: "unsupported format")
    /// Import
    public static let importToolbarButton = L10n.tr("Localizable", "AlbumDetailView.ImportToolbarButton", fallback: "Import")
    /// Import from Photos
    public static let importToolbarButtonAccessibilityLabel = L10n.tr("Localizable", "AlbumDetailView.ImportToolbarButtonAccessibilityLabel", fallback: "Import from Photos")
    /// Leave the app open and connected to WiFi for best results.
    public static let largeImportWarningMessage = L10n.tr("Localizable", "AlbumDetailView.LargeImportWarningMessage", fallback: "Leave the app open and connected to WiFi for best results.")
    /// For Faster Imports
    public static let largeImportWarningTitle = L10n.tr("Localizable", "AlbumDetailView.LargeImportWarningTitle", fallback: "For Faster Imports")
    /// Moved %@ %@ to %@
    public static func movedToast(_ p1: Any, _ p2: Any, _ p3: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.MovedToast", String(describing: p1), String(describing: p2), String(describing: p3), fallback: "Moved %@ %@ to %@")
    }
    /// Failed to move %@ %@
    public static func moveErrorToast(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.MoveErrorToast", String(describing: p1), String(describing: p2), fallback: "Failed to move %@ %@")
    }
    /// The album was not moved and stays where it is. %@
    public static func moveFailedAlertMessage(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.MoveFailedAlertMessage", String(describing: p1), fallback: "The album was not moved and stays where it is. %@")
    }
    /// Couldn't Move Album
    public static let moveFailedAlertTitle = L10n.tr("Localizable", "AlbumDetailView.MoveFailedAlertTitle", fallback: "Couldn't Move Album")
    /// Move Media
    public static let moveMedia = L10n.tr("Localizable", "AlbumDetailView.MoveMedia", fallback: "Move Media")
    /// Because you don't have a paid license to Encamera, you will only be able to view 10 images in the app. If you delete images from your photo library, you may not be able to view them without a paid license.
    public static let noLicenseDeletionWarningMessage = L10n.tr("Localizable", "AlbumDetailView.NoLicenseDeletionWarningMessage", fallback: "Because you don't have a paid license to Encamera, you will only be able to view 10 images in the app. If you delete images from your photo library, you may not be able to view them without a paid license.")
    /// I Understand
    public static let noLicenseDeletionWarningPrimaryButton = L10n.tr("Localizable", "AlbumDetailView.NoLicenseDeletionWarningPrimaryButton", fallback: "I Understand")
    /// ⚠️ Important ⚠️
    public static let noLicenseDeletionWarningTitle = L10n.tr("Localizable", "AlbumDetailView.NoLicenseDeletionWarningTitle", fallback: "⚠️ Important ⚠️")
    /// No media found
    public static let noMediaFound = L10n.tr("Localizable", "AlbumDetailView.NoMediaFound", fallback: "No media found")
    /// Take a New Picture
    public static let openCamera = L10n.tr("Localizable", "AlbumDetailView.OpenCamera", fallback: "Take a New Picture")
    /// Open Settings
    public static let openSettings = L10n.tr("Localizable", "AlbumDetailView.OpenSettings", fallback: "Open Settings")
    /// Do you want to delete the images from your photo library after importing them? Encamera requires permission to your photo library to do this.
    public static let photoAccessAlertMessage = L10n.tr("Localizable", "AlbumDetailView.PhotoAccessAlertMessage", fallback: "Do you want to delete the images from your photo library after importing them? Encamera requires permission to your photo library to do this.")
    /// Delete
    public static let photoAccessAlertPrimaryButton = L10n.tr("Localizable", "AlbumDetailView.PhotoAccessAlertPrimaryButton", fallback: "Delete")
    /// Not Now
    public static let photoAccessAlertSecondaryButton = L10n.tr("Localizable", "AlbumDetailView.PhotoAccessAlertSecondaryButton", fallback: "Not Now")
    /// Delete After Import?
    public static let photoAccessAlertTitle = L10n.tr("Localizable", "AlbumDetailView.PhotoAccessAlertTitle", fallback: "Delete After Import?")
    /// Photo Access Required
    public static let photoAccessRequired = L10n.tr("Localizable", "AlbumDetailView.PhotoAccessRequired", fallback: "Photo Access Required")
    /// Please grant access to your photo library in Settings to import photos.
    public static let photoAccessSettings = L10n.tr("Localizable", "AlbumDetailView.PhotoAccessSettings", fallback: "Please grant access to your photo library in Settings to import photos.")
    /// Disable Album Cover
    public static let removeCoverImage = L10n.tr("Localizable", "AlbumDetailView.RemoveCoverImage", fallback: "Disable Album Cover")
    /// Rename Album
    public static let renameAlbum = L10n.tr("Localizable", "AlbumDetailView.RenameAlbum", fallback: "Rename Album")
    /// Default to Latest Image
    public static let resetCoverImage = L10n.tr("Localizable", "AlbumDetailView.ResetCoverImage", fallback: "Default to Latest Image")
    /// Select Media
    public static let select = L10n.tr("Localizable", "AlbumDetailView.Select", fallback: "Select Media")
    /// this device
    public static let storageLocationThisDevice = L10n.tr("Localizable", "AlbumDetailView.StorageLocationThisDevice", fallback: "this device")
    /// Saved on %@
    public static func storageMenuSubtitle(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.StorageMenuSubtitle", String(describing: p1), fallback: "Saved on %@")
    }
    /// Unhide
    public static let unhideAlbumRowTitle = L10n.tr("Localizable", "AlbumDetailView.UnhideAlbumRowTitle", fallback: "Unhide")
    public enum SortFilter {
      /// Sort & Filter
      public static let dateAddedNewest = L10n.tr("Localizable", "AlbumDetailView.SortFilter.DateAddedNewest", fallback: "Date Added: Newest First")
      /// Date Added: Oldest First
      public static let dateAddedOldest = L10n.tr("Localizable", "AlbumDetailView.SortFilter.DateAddedOldest", fallback: "Date Added: Oldest First")
      /// Date Captured: Newest First
      public static let dateCapturedNewest = L10n.tr("Localizable", "AlbumDetailView.SortFilter.DateCapturedNewest", fallback: "Date Captured: Newest First")
      /// Date Captured: Oldest First
      public static let dateCapturedOldest = L10n.tr("Localizable", "AlbumDetailView.SortFilter.DateCapturedOldest", fallback: "Date Captured: Oldest First")
      /// Filter by Type
      public static let filterByType = L10n.tr("Localizable", "AlbumDetailView.SortFilter.FilterByType", fallback: "Filter by Type")
      /// Live Photos
      public static let livePhotos = L10n.tr("Localizable", "AlbumDetailView.SortFilter.LivePhotos", fallback: "Live Photos")
      /// Photos
      public static let photos = L10n.tr("Localizable", "AlbumDetailView.SortFilter.Photos", fallback: "Photos")
      /// Reset Filters
      public static let resetFilters = L10n.tr("Localizable", "AlbumDetailView.SortFilter.ResetFilters", fallback: "Reset Filters")
      /// Videos
      public static let videos = L10n.tr("Localizable", "AlbumDetailView.SortFilter.Videos", fallback: "Videos")
    }
  }
  public enum AlbumSelectionModal {
    /// Select an album to move %@ items to
    public static func description(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AlbumSelectionModal.Description", String(describing: p1), fallback: "Select an album to move %@ items to")
    }
    /// Move
    public static let move = L10n.tr("Localizable", "AlbumSelectionModal.Move", fallback: "Move")
    /// Type to create or open
    public static let newOrHiddenAlbumSubtitle = L10n.tr("Localizable", "AlbumSelectionModal.NewOrHiddenAlbumSubtitle", fallback: "Type to create or open")
    /// New or hidden album
    public static let newOrHiddenAlbumTitle = L10n.tr("Localizable", "AlbumSelectionModal.NewOrHiddenAlbumTitle", fallback: "New or hidden album")
    /// Create another album first.
    public static let noAlbumsDescription = L10n.tr("Localizable", "AlbumSelectionModal.NoAlbumsDescription", fallback: "Create another album first.")
    /// No Other Albums
    public static let noAlbumsTitle = L10n.tr("Localizable", "AlbumSelectionModal.NoAlbumsTitle", fallback: "No Other Albums")
    /// ./Encamera/AlbumManagement/AlbumSelectionModal.swift
    public static let title = L10n.tr("Localizable", "AlbumSelectionModal.Title", fallback: "Move to Album")
  }
  public enum Alert {
    public enum LoadingFile {
      /// Please wait...
      public static let message = L10n.tr("Localizable", "Alert.LoadingFile.Message", fallback: "Please wait...")
      /// Loading File
      public static let title = L10n.tr("Localizable", "Alert.LoadingFile.Title", fallback: "Loading File")
    }
  }
  public enum AppIcon {
    /// Calculator
    public static let calculator = L10n.tr("Localizable", "AppIcon.Calculator", fallback: "Calculator")
    /// Clock
    public static let clock = L10n.tr("Localizable", "AppIcon.Clock", fallback: "Clock")
    /// Compass
    public static let compass = L10n.tr("Localizable", "AppIcon.Compass", fallback: "Compass")
    /// Jazz
    public static let jazz = L10n.tr("Localizable", "AppIcon.Jazz", fallback: "Jazz")
    /// Light
    public static let light = L10n.tr("Localizable", "AppIcon.Light", fallback: "Light")
    /// Numbers
    public static let numbers = L10n.tr("Localizable", "AppIcon.Numbers", fallback: "Numbers")
    /// Default
    public static let primary = L10n.tr("Localizable", "AppIcon.Primary", fallback: "Default")
  }
  public enum AppIconSelection {
    /// Current
    public static let currentIcon = L10n.tr("Localizable", "AppIconSelection.CurrentIcon", fallback: "Current")
    /// Upgrade to customize your app icon
    public static let premiumDescription = L10n.tr("Localizable", "AppIconSelection.PremiumDescription", fallback: "Upgrade to customize your app icon")
    /// Premium Feature
    public static let premiumFeature = L10n.tr("Localizable", "AppIconSelection.PremiumFeature", fallback: "Premium Feature")
    /// Select an icon
    public static let selectIcon = L10n.tr("Localizable", "AppIconSelection.SelectIcon", fallback: "Select an icon")
    /// ./Encamera/Settings/AppIconSelectionView.swift - App Icon Selection
    public static let title = L10n.tr("Localizable", "AppIconSelection.Title", fallback: "App Icon")
  }
  public enum AskForReview {
    /// Ask me later
    public static let askMeLater = L10n.tr("Localizable", "AskForReview.AskMeLater", fallback: "Ask me later")
    /// Are you enjoying the app?
    public static let enjoyingTheApp = L10n.tr("Localizable", "AskForReview.EnjoyingTheApp", fallback: "Are you enjoying the app?")
  }
  public enum AuthenticationMethod {
    /// Cancel
    public static let cancel = L10n.tr("Localizable", "AuthenticationMethod.Cancel", fallback: "Cancel")
    /// Do you really want to disable %@?
    public static func confirmDisable(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AuthenticationMethod.ConfirmDisable", String(describing: p1), fallback: "Do you really want to disable %@?")
    }
    /// Do you really want to disable %@?
    public static func confirmDisableFaceID(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AuthenticationMethod.ConfirmDisableFaceID", String(describing: p1), fallback: "Do you really want to disable %@?")
    }
    /// Do you really want to disable %@? This will clear the password you have stored.
    public static func confirmDisablePassword(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AuthenticationMethod.ConfirmDisablePassword", String(describing: p1), fallback: "Do you really want to disable %@? This will clear the password you have stored.")
    }
    /// Do you really want to disable %@? This will clear the PIN code you have stored.
    public static func confirmDisablePinCode(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AuthenticationMethod.ConfirmDisablePinCode", String(describing: p1), fallback: "Do you really want to disable %@? This will clear the PIN code you have stored.")
    }
    /// Disable
    public static let disable = L10n.tr("Localizable", "AuthenticationMethod.Disable", fallback: "Disable")
    /// Disable Passcode
    public static let disableTitle = L10n.tr("Localizable", "AuthenticationMethod.DisableTitle", fallback: "Disable Passcode")
    /// %@ cannot be used with the currently selected methods. PIN and Password cannot be used together.
    public static func incompatibleDetail(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AuthenticationMethod.IncompatibleDetail", String(describing: p1), fallback: "%@ cannot be used with the currently selected methods. PIN and Password cannot be used together.")
    }
    /// The selected authentication methods are incompatible.
    public static let incompatibleMessage = L10n.tr("Localizable", "AuthenticationMethod.IncompatibleMessage", fallback: "The selected authentication methods are incompatible.")
    /// Authentication Method View
    public static let multipleMethodsInfo = L10n.tr("Localizable", "AuthenticationMethod.MultipleMethodsInfo", fallback: "You can select multiple authentication methods")
    /// OK
    public static let ok = L10n.tr("Localizable", "AuthenticationMethod.OK", fallback: "OK")
    /// Tap to disable the selected method
    public static let tapToDisableBanner = L10n.tr("Localizable", "AuthenticationMethod.TapToDisableBanner", fallback: "Tap to disable the selected method")
    public enum SecurityLevel {
      /// Authentication Method Security Levels
      public static let faceID = L10n.tr("Localizable", "AuthenticationMethod.SecurityLevel.FaceID", fallback: "Low protection")
      /// Most secure option
      public static let password = L10n.tr("Localizable", "AuthenticationMethod.SecurityLevel.password", fallback: "Most secure option")
      /// Moderate protection
      public static let pinCode = L10n.tr("Localizable", "AuthenticationMethod.SecurityLevel.PinCode", fallback: "Moderate protection")
      /// Quick but less secure
      public static let pinCode4Digit = L10n.tr("Localizable", "AuthenticationMethod.SecurityLevel.pinCode4Digit", fallback: "Quick but less secure")
      /// More secure PIN code
      public static let pinCode6Digit = L10n.tr("Localizable", "AuthenticationMethod.SecurityLevel.pinCode6Digit", fallback: "More secure PIN code")
    }
    public enum TextDescription {
      /// Authentication Method Text Descriptions
      public static let faceID = L10n.tr("Localizable", "AuthenticationMethod.TextDescription.FaceID", fallback: "Face ID")
      /// Password
      public static let password = L10n.tr("Localizable", "AuthenticationMethod.TextDescription.Password", fallback: "Password")
      /// Pin Code
      public static let pinCode = L10n.tr("Localizable", "AuthenticationMethod.TextDescription.PinCode", fallback: "Pin Code")
      /// Authentication Method Types
      public static let pinCode4Digit = L10n.tr("Localizable", "AuthenticationMethod.TextDescription.pinCode4Digit", fallback: "4-digit PIN")
      /// 6-digit PIN
      public static let pinCode6Digit = L10n.tr("Localizable", "AuthenticationMethod.TextDescription.pinCode6Digit", fallback: "6-digit PIN")
    }
  }
  public enum AuthenticationView {
    /// Encamera can't be unlocked
    public static let cannotUnlock = L10n.tr("Localizable", "AuthenticationView.CannotUnlock", fallback: "Encamera can't be unlocked")
    /// Forgot Password? Reset App
    public static let forgotPassword = L10n.tr("Localizable", "AuthenticationView.ForgotPassword", fallback: "Forgot Password? Reset App")
    /// You can retry your password in %@
    public static func retryIn(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AuthenticationView.RetryIn", String(describing: p1), fallback: "You can retry your password in %@")
    }
    /// ./Encamera/AuthenticationView/AuthenticationView.swift
    public static let tooManyAttempts = L10n.tr("Localizable", "AuthenticationView.TooManyAttempts", fallback: "Too many attempts")
    /// Try Again
    public static let tryAgain = L10n.tr("Localizable", "AuthenticationView.TryAgain", fallback: "Try Again")
  }
  public enum BackgroundTaskProgress {
    /// ./Encamera/Components/ImportProgress/BackgroundTaskProgressView.swift - Index Build
    public static let buildingIndex = L10n.tr("Localizable", "BackgroundTaskProgress.BuildingIndex", fallback: "Optimizing your photo library...")
    /// Edit cancelled
    public static let editCancelled = L10n.tr("Localizable", "BackgroundTaskProgress.EditCancelled", fallback: "Edit cancelled")
    /// ./Encamera/Components/ImportProgress/BackgroundTaskProgressView.swift - Edit Operations
    public static let editCompleted = L10n.tr("Localizable", "BackgroundTaskProgress.EditCompleted", fallback: "Edit completed")
    /// Editing...
    public static let editing = L10n.tr("Localizable", "BackgroundTaskProgress.Editing", fallback: "Editing...")
    /// Edit stopped
    public static let editStopped = L10n.tr("Localizable", "BackgroundTaskProgress.EditStopped", fallback: "Edit stopped")
    /// Photo library optimized
    public static let indexCompleted = L10n.tr("Localizable", "BackgroundTaskProgress.IndexCompleted", fallback: "Photo library optimized")
    /// Move to iCloud canceled
    public static let migrateCanceled = L10n.tr("Localizable", "BackgroundTaskProgress.MigrateCanceled", fallback: "Move to iCloud canceled")
    /// ./Encamera/Components/ImportProgress/BackgroundTaskProgressView.swift - CloudKit Migration
    public static let migrateCompleted = L10n.tr("Localizable", "BackgroundTaskProgress.MigrateCompleted", fallback: "Moved to iCloud")
    /// Move to iCloud stopped
    public static let migrateStopped = L10n.tr("Localizable", "BackgroundTaskProgress.MigrateStopped", fallback: "Move to iCloud stopped")
    /// Move to this device canceled
    public static let migrateToLocalCanceled = L10n.tr("Localizable", "BackgroundTaskProgress.MigrateToLocalCanceled", fallback: "Move to this device canceled")
    /// Moved to this device
    public static let migrateToLocalCompleted = L10n.tr("Localizable", "BackgroundTaskProgress.MigrateToLocalCompleted", fallback: "Moved to this device")
    /// Move to this device stopped
    public static let migrateToLocalStopped = L10n.tr("Localizable", "BackgroundTaskProgress.MigrateToLocalStopped", fallback: "Move to this device stopped")
    /// Moving %@ albums to iCloud
    public static func migratingBatches(_ p1: Any) -> String {
      return L10n.tr("Localizable", "BackgroundTaskProgress.MigratingBatches", String(describing: p1), fallback: "Moving %@ albums to iCloud")
    }
    /// Moving %@ of %@ to iCloud
    public static func migratingProgress(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "BackgroundTaskProgress.MigratingProgress", String(describing: p1), String(describing: p2), fallback: "Moving %@ of %@ to iCloud")
    }
    /// Move canceled
    public static let moveCanceled = L10n.tr("Localizable", "BackgroundTaskProgress.MoveCanceled", fallback: "Move canceled")
    /// ./Encamera/Components/ImportProgress/BackgroundTaskProgressView.swift - Move Operations
    public static let moveCompleted = L10n.tr("Localizable", "BackgroundTaskProgress.MoveCompleted", fallback: "Move completed")
    /// Move stopped
    public static let moveStopped = L10n.tr("Localizable", "BackgroundTaskProgress.MoveStopped", fallback: "Move stopped")
    /// Moving %@ batches
    public static func movingBatches(_ p1: Any) -> String {
      return L10n.tr("Localizable", "BackgroundTaskProgress.MovingBatches", String(describing: p1), fallback: "Moving %@ batches")
    }
    /// Moving %@ of %@
    public static func movingProgress(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "BackgroundTaskProgress.MovingProgress", String(describing: p1), String(describing: p2), fallback: "Moving %@ of %@")
    }
    /// No active tasks
    public static let noActiveTasks = L10n.tr("Localizable", "BackgroundTaskProgress.NoActiveTasks", fallback: "No active tasks")
  }
  public enum BillingFrequency {
    /// 1 Year of Updates
    public static let lifetimeLimited = L10n.tr("Localizable", "BillingFrequency.LifetimeLimited", fallback: "1 Year of Updates")
    /// Unlimited Updates
    public static let lifetimeUnlimited = L10n.tr("Localizable", "BillingFrequency.LifetimeUnlimited", fallback: "Unlimited Updates")
    /// ./Encamera/Store/Extensions/Package+PremiumPurchasable.swift
    public static let perMonth = L10n.tr("Localizable", "BillingFrequency.PerMonth", fallback: "per month")
    /// per week
    public static let perWeek = L10n.tr("Localizable", "BillingFrequency.PerWeek", fallback: "per week")
    /// per year
    public static let perYear = L10n.tr("Localizable", "BillingFrequency.PerYear", fallback: "per year")
  }
  public enum BiometricAvailability {
    /// Shown when biometrics is the only way into the app and it cannot run.
    public static let genericName = L10n.tr("Localizable", "BiometricAvailability.GenericName", fallback: "Biometric unlock")
    public enum CannotUnlock {
      /// %@ is turned off for Encamera. Turn it back on in Settings > Encamera, then try again.
      public static func deniedBySystemSettings(_ p1: Any) -> String {
        return L10n.tr("Localizable", "BiometricAvailability.CannotUnlock.DeniedBySystemSettings", String(describing: p1), fallback: "%@ is turned off for Encamera. Turn it back on in Settings > Encamera, then try again.")
      }
      /// %@ is locked after too many failed attempts. Lock your device and unlock it with your device passcode, then try again.
      public static func lockedOut(_ p1: Any) -> String {
        return L10n.tr("Localizable", "BiometricAvailability.CannotUnlock.LockedOut", String(describing: p1), fallback: "%@ is locked after too many failed attempts. Lock your device and unlock it with your device passcode, then try again.")
      }
      /// This device has no biometric unlock, and this account has no passcode.
      public static let noHardware = L10n.tr("Localizable", "BiometricAvailability.CannotUnlock.NoHardware", fallback: "This device has no biometric unlock, and this account has no passcode.")
      /// %@ hasn't been turned on for Encamera on this device, and this account has no passcode.
      public static func notEnabled(_ p1: Any) -> String {
        return L10n.tr("Localizable", "BiometricAvailability.CannotUnlock.NotEnabled", String(describing: p1), fallback: "%@ hasn't been turned on for Encamera on this device, and this account has no passcode.")
      }
      /// No face or fingerprint is enrolled on this device. Set one up in Settings, then try again.
      public static let notEnrolled = L10n.tr("Localizable", "BiometricAvailability.CannotUnlock.NotEnrolled", fallback: "No face or fingerprint is enrolled on this device. Set one up in Settings, then try again.")
      /// This device has no passcode, which turns off Face ID and Touch ID. Set a device passcode in Settings, then try again.
      public static let passcodeNotSet = L10n.tr("Localizable", "BiometricAvailability.CannotUnlock.PasscodeNotSet", fallback: "This device has no passcode, which turns off Face ID and Touch ID. Set a device passcode in Settings, then try again.")
      /// Biometric unlock isn't available right now (error %d), and this account has no passcode.
      public static func unavailable(_ p1: Int) -> String {
        return L10n.tr("Localizable", "BiometricAvailability.CannotUnlock.Unavailable", p1, fallback: "Biometric unlock isn't available right now (error %d), and this account has no passcode.")
      }
    }
  }
  public enum Cms {
    /// Failed to load promotional banners
    public static let loadingError = L10n.tr("Localizable", "CMS.LoadingError", fallback: "Failed to load promotional banners")
    /// ./Encamera/Services/CMS/ContentfulService.swift
    public static let networkError = L10n.tr("Localizable", "CMS.NetworkError", fallback: "Unable to load promotional content. Using cached data.")
    /// No promotional banners available
    public static let noBannersAvailable = L10n.tr("Localizable", "CMS.NoBannersAvailable", fallback: "No promotional banners available")
  }
  public enum ChangingYourAuthenticationMethodWillRequireSettingUpANewPINOrPassword {
    /// Changing your authentication method will require setting up a new PIN or password. Would you like to continue?
    public static let wouldYouLikeToContinue = L10n.tr("Localizable", "Changing your authentication method will require setting up a new PIN or password. Would you like to continue?", fallback: "Changing your authentication method will require setting up a new PIN or password. Would you like to continue?")
  }
  public enum CloudKitMigration {
    /// Sign in to iCloud in Settings, then resume the move.
    public static let accountUnavailableMessage = L10n.tr("Localizable", "CloudKitMigration.AccountUnavailableMessage", fallback: "Sign in to iCloud in Settings, then resume the move.")
    /// iCloud is unavailable
    public static let accountUnavailableTitle = L10n.tr("Localizable", "CloudKitMigration.AccountUnavailableTitle", fallback: "iCloud is unavailable")
    /// Not now
    public static let alertCancel = L10n.tr("Localizable", "CloudKitMigration.AlertCancel", fallback: "Not now")
    /// Move to iCloud
    public static let alertConfirm = L10n.tr("Localizable", "CloudKitMigration.AlertConfirm", fallback: "Move to iCloud")
    /// This uploads %@ items (%@) to iCloud and can take about %@. Stay on Wi-Fi and keep Encamera open — you can switch apps, but don't force-quit. Your files stay end-to-end encrypted.
    public static func alertMessage(_ p1: Any, _ p2: Any, _ p3: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.AlertMessage", String(describing: p1), String(describing: p2), String(describing: p3), fallback: "This uploads %@ items (%@) to iCloud and can take about %@. Stay on Wi-Fi and keep Encamera open — you can switch apps, but don't force-quit. Your files stay end-to-end encrypted.")
    }
    /// ./Encamera/AlbumManagement/AlbumDetailView.swift - Move a local album to iCloud (CloudKit)
    public static let alertTitle = L10n.tr("Localizable", "CloudKitMigration.AlertTitle", fallback: "Move this album to iCloud?")
    /// %@ moved, %@ still on this device
    public static func bannerCounts(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.BannerCounts", String(describing: p1), String(describing: p2), fallback: "%@ moved, %@ still on this device")
    }
    /// ./Encamera/AlbumManagement/PartialMigrationBanner.swift - Persistent banner for an album left split between this device and iCloud
    public static let bannerMessage = L10n.tr("Localizable", "CloudKitMigration.BannerMessage", fallback: "This album is split between this device and iCloud.")
    /// Connect to fast Wi-Fi before you start. Moving %@ items (%@) off iCloud Drive downloads them to this device and then uploads them to iCloud, so every file travels twice — about %@ on a good connection, and much longer on cellular. Keep Encamera open; you can switch apps, but don't force-quit. Your files stay end-to-end encrypted.
    public static func driveAlertMessage(_ p1: Any, _ p2: Any, _ p3: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.DriveAlertMessage", String(describing: p1), String(describing: p2), String(describing: p3), fallback: "Connect to fast Wi-Fi before you start. Moving %@ items (%@) off iCloud Drive downloads them to this device and then uploads them to iCloud, so every file travels twice — about %@ on a good connection, and much longer on cellular. Keep Encamera open; you can switch apps, but don't force-quit. Your files stay end-to-end encrypted.")
    }
    /// Not now
    public static let drivePromptDismiss = L10n.tr("Localizable", "CloudKitMigration.DrivePromptDismiss", fallback: "Not now")
    /// iCloud Drive storage is no longer supported. Move your albums to iCloud to keep them syncing across your devices.
    public static let drivePromptMessage = L10n.tr("Localizable", "CloudKitMigration.DrivePromptMessage", fallback: "iCloud Drive storage is no longer supported. Move your albums to iCloud to keep them syncing across your devices.")
    /// Move to iCloud
    public static let drivePromptMove = L10n.tr("Localizable", "CloudKitMigration.DrivePromptMove", fallback: "Move to iCloud")
    /// %@ albums are still on iCloud Drive
    public static func drivePromptTitleMany(_ p1: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.DrivePromptTitleMany", String(describing: p1), fallback: "%@ albums are still on iCloud Drive")
    }
    /// ./Encamera/AlbumManagement/ICloudDriveMigrationPrompt.swift - placeholder prompt offering to move deprecated iCloud Drive albums to CloudKit (design pending)
    public static let drivePromptTitleOne = L10n.tr("Localizable", "CloudKitMigration.DrivePromptTitleOne", fallback: "1 album is still on iCloud Drive")
    /// less than a minute
    public static let estimateLessThanAMinute = L10n.tr("Localizable", "CloudKitMigration.EstimateLessThanAMinute", fallback: "less than a minute")
    /// %@ minutes
    public static func estimateMinutes(_ p1: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.EstimateMinutes", String(describing: p1), fallback: "%@ minutes")
    }
    /// more than an hour
    public static let estimateOverAnHour = L10n.tr("Localizable", "CloudKitMigration.EstimateOverAnHour", fallback: "more than an hour")
    /// Something went wrong: %@. You may need to be connected to Wi-Fi to continue. You can resume the move.
    public static func failedMessage(_ p1: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.FailedMessage", String(describing: p1), fallback: "Something went wrong: %@. You may need to be connected to Wi-Fi to continue. You can resume the move.")
    }
    /// The move to iCloud didn't finish
    public static let failedTitle = L10n.tr("Localizable", "CloudKitMigration.FailedTitle", fallback: "The move to iCloud didn't finish")
    /// Stop the move
    public static let overlayCancel = L10n.tr("Localizable", "CloudKitMigration.OverlayCancel", fallback: "Stop the move")
    /// %@ couldn't be moved yet
    public static func overlayFailedItems(_ p1: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.OverlayFailedItems", String(describing: p1), fallback: "%@ couldn't be moved yet")
    }
    /// %@ of %@ items
    public static func overlayItemProgress(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.OverlayItemProgress", String(describing: p1), String(describing: p2), fallback: "%@ of %@ items")
    }
    /// Keep Encamera open. You can switch apps, but don't force-quit.
    public static let overlayKeepOpen = L10n.tr("Localizable", "CloudKitMigration.OverlayKeepOpen", fallback: "Keep Encamera open. You can switch apps, but don't force-quit.")
    /// Downloading from iCloud
    public static let overlayPhaseDownloading = L10n.tr("Localizable", "CloudKitMigration.OverlayPhaseDownloading", fallback: "Downloading from iCloud")
    /// Downloading from iCloud Drive
    public static let overlayPhaseMaterializing = L10n.tr("Localizable", "CloudKitMigration.OverlayPhaseMaterializing", fallback: "Downloading from iCloud Drive")
    /// Preparing
    public static let overlayPhasePreparing = L10n.tr("Localizable", "CloudKitMigration.OverlayPhasePreparing", fallback: "Preparing")
    /// Removing local copy
    public static let overlayPhaseRemovingLocalCopy = L10n.tr("Localizable", "CloudKitMigration.OverlayPhaseRemovingLocalCopy", fallback: "Removing local copy")
    /// Removing iCloud copy
    public static let overlayPhaseRemovingRemoteCopy = L10n.tr("Localizable", "CloudKitMigration.OverlayPhaseRemovingRemoteCopy", fallback: "Removing iCloud copy")
    /// Retrying
    public static let overlayPhaseRetrying = L10n.tr("Localizable", "CloudKitMigration.OverlayPhaseRetrying", fallback: "Retrying")
    /// Uploading
    public static let overlayPhaseUploading = L10n.tr("Localizable", "CloudKitMigration.OverlayPhaseUploading", fallback: "Uploading")
    /// Verifying in iCloud
    public static let overlayPhaseVerifying = L10n.tr("Localizable", "CloudKitMigration.OverlayPhaseVerifying", fallback: "Verifying in iCloud")
    /// About %@ remaining
    public static func overlayTimeRemaining(_ p1: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.OverlayTimeRemaining", String(describing: p1), fallback: "About %@ remaining")
    }
    /// ./Encamera/AlbumManagement/MigrationStatusOverlay.swift - Blocking status view shown for the duration of a move to iCloud
    public static let overlayTitle = L10n.tr("Localizable", "CloudKitMigration.OverlayTitle", fallback: "Moving to iCloud")
    /// Moving to This Device
    public static let overlayTitleToLocal = L10n.tr("Localizable", "CloudKitMigration.OverlayTitleToLocal", fallback: "Moving to This Device")
    /// %@ total
    public static func overlayTotalSize(_ p1: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.OverlayTotalSize", String(describing: p1), fallback: "%@ total")
    }
    /// Some items in this album were already moved to iCloud before the move was stopped. They won't appear here until the move finishes. Resume to finish moving the rest.
    public static let partialMessage = L10n.tr("Localizable", "CloudKitMigration.PartialMessage", fallback: "Some items in this album were already moved to iCloud before the move was stopped. They won't appear here until the move finishes. Resume to finish moving the rest.")
    /// Album partially moved
    public static let partialTitle = L10n.tr("Localizable", "CloudKitMigration.PartialTitle", fallback: "Album partially moved")
    /// Free up space in iCloud, then resume the move.
    public static let quotaMessage = L10n.tr("Localizable", "CloudKitMigration.QuotaMessage", fallback: "Free up space in iCloud, then resume the move.")
    /// iCloud storage is full
    public static let quotaTitle = L10n.tr("Localizable", "CloudKitMigration.QuotaTitle", fallback: "iCloud storage is full")
    /// Resume
    public static let resume = L10n.tr("Localizable", "CloudKitMigration.Resume", fallback: "Resume")
    /// iCloud isn't ready for this version of Encamera yet. Your photos are safe on this device — please make sure Encamera is up to date and try again later.
    public static let schemaNotDeployedMessage = L10n.tr("Localizable", "CloudKitMigration.SchemaNotDeployedMessage", fallback: "iCloud isn't ready for this version of Encamera yet. Your photos are safe on this device — please make sure Encamera is up to date and try again later.")
    /// iCloud can't accept this album yet
    public static let schemaNotDeployedTitle = L10n.tr("Localizable", "CloudKitMigration.SchemaNotDeployedTitle", fallback: "iCloud can't accept this album yet")
  }
  public enum Common {
    /// Cancel
    public static let cancel = L10n.tr("Localizable", "Common.Cancel", fallback: "Cancel")
    /// Confirm
    public static let confirm = L10n.tr("Localizable", "Common.Confirm", fallback: "Confirm")
  }
  public enum CompletedImportHistory {
    /// Clear All
    public static let clearAll = L10n.tr("Localizable", "CompletedImportHistory.ClearAll", fallback: "Clear All")
    /// This will delete %@ photo(s) from your Photo Library.
    public static func deleteConfirmMessage(_ p1: Any) -> String {
      return L10n.tr("Localizable", "CompletedImportHistory.DeleteConfirmMessage", String(describing: p1), fallback: "This will delete %@ photo(s) from your Photo Library.")
    }
    /// Delete from Photo Library?
    public static let deleteConfirmTitle = L10n.tr("Localizable", "CompletedImportHistory.DeleteConfirmTitle", fallback: "Delete from Photo Library?")
    /// Delete from Camera Roll
    public static let deleteFromCameraRoll = L10n.tr("Localizable", "CompletedImportHistory.DeleteFromCameraRoll", fallback: "Delete from Camera Roll")
    /// No completed imports
    public static let emptyState = L10n.tr("Localizable", "CompletedImportHistory.EmptyState", fallback: "No completed imports")
    /// %@ of %@ imported
    public static func itemsImported(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "CompletedImportHistory.ItemsImported", String(describing: p1), String(describing: p2), fallback: "%@ of %@ imported")
    }
    /// ./Encamera/Components/ImportProgress/CompletedImportHistoryView.swift
    public static let title = L10n.tr("Localizable", "CompletedImportHistory.Title", fallback: "Import History")
    /// View Import History
    public static let viewImportHistory = L10n.tr("Localizable", "CompletedImportHistory.ViewImportHistory", fallback: "View Import History")
  }
  public enum CreateAlbumModal {
    /// Create Album
    public static let createAlbum = L10n.tr("Localizable", "CreateAlbumModal.CreateAlbum", fallback: "Create Album")
    /// ./Encamera/AlbumManagement/CreateAlbumModal.swift - Create Album Modal
    public static let headerText = L10n.tr("Localizable", "CreateAlbumModal.HeaderText", fallback: "Name this encrypted album")
    /// Your memories
    public static let placeholder = L10n.tr("Localizable", "CreateAlbumModal.Placeholder", fallback: "Your memories")
  }
  public enum CredentialConflict {
    /// Keep this device's account
    public static let keepLocal = L10n.tr("Localizable", "CredentialConflict.KeepLocal", fallback: "Keep this device's account")
    /// This device has its own Encamera account, and a different account synced in from another device via iCloud. Which one do you want to use on this device?
    public static let message = L10n.tr("Localizable", "CredentialConflict.Message", fallback: "This device has its own Encamera account, and a different account synced in from another device via iCloud. Which one do you want to use on this device?")
    /// ./Encamera/EncameraApp.swift - Credential conflict prompt (two accounts detected)
    public static let title = L10n.tr("Localizable", "CredentialConflict.Title", fallback: "Another account found")
    /// Use the other device's account
    public static let useSynced = L10n.tr("Localizable", "CredentialConflict.UseSynced", fallback: "Use the other device's account")
    /// You'll unlock with the other device's passcode. Photos taken on this device before switching may require switching back to view.
    public static let useSyncedWarning = L10n.tr("Localizable", "CredentialConflict.UseSyncedWarning", fallback: "You'll unlock with the other device's passcode. Photos taken on this device before switching may require switching back to view.")
  }
  public enum CustomPhotoPicker {
    /// Add
    public static let add = L10n.tr("Localizable", "CustomPhotoPicker.Add", fallback: "Add")
    /// All Photos
    public static let allPhotos = L10n.tr("Localizable", "CustomPhotoPicker.AllPhotos", fallback: "All Photos")
    /// Open Settings
    public static let emptyDeniedButton = L10n.tr("Localizable", "CustomPhotoPicker.EmptyDeniedButton", fallback: "Open Settings")
    /// Encamera needs access to your photo library to import photos. You can turn it on in Settings.
    public static let emptyDeniedMessage = L10n.tr("Localizable", "CustomPhotoPicker.EmptyDeniedMessage", fallback: "Encamera needs access to your photo library to import photos. You can turn it on in Settings.")
    /// Photo access is off
    public static let emptyDeniedTitle = L10n.tr("Localizable", "CustomPhotoPicker.EmptyDeniedTitle", fallback: "Photo access is off")
    /// Show All Photos
    public static let emptyFilteredButton = L10n.tr("Localizable", "CustomPhotoPicker.EmptyFilteredButton", fallback: "Show All Photos")
    /// No photos in your library match this filter.
    public static let emptyFilteredMessage = L10n.tr("Localizable", "CustomPhotoPicker.EmptyFilteredMessage", fallback: "No photos in your library match this filter.")
    /// Nothing to show here
    public static let emptyFilteredTitle = L10n.tr("Localizable", "CustomPhotoPicker.EmptyFilteredTitle", fallback: "Nothing to show here")
    /// Select media
    public static let emptyLimitedButton = L10n.tr("Localizable", "CustomPhotoPicker.EmptyLimitedButton", fallback: "Select media")
    /// Give Encamera access to at least one photo or video.
    public static let emptyLimitedMessage = L10n.tr("Localizable", "CustomPhotoPicker.EmptyLimitedMessage", fallback: "Give Encamera access to at least one photo or video.")
    /// No media selected
    public static let emptyLimitedTitle = L10n.tr("Localizable", "CustomPhotoPicker.EmptyLimitedTitle", fallback: "No media selected")
    /// Please grant full access to your photo library to use swipe selection. You can change this in Settings.
    public static let grantAccessMessage = L10n.tr("Localizable", "CustomPhotoPicker.GrantAccessMessage", fallback: "Please grant full access to your photo library to use swipe selection. You can change this in Settings.")
    /// Select more media or grant full access
    public static let limitedAccessSubtitle = L10n.tr("Localizable", "CustomPhotoPicker.LimitedAccessSubtitle", fallback: "Select more media or grant full access")
    /// Limited access
    public static let limitedAccessTitle = L10n.tr("Localizable", "CustomPhotoPicker.LimitedAccessTitle", fallback: "Limited access")
    /// Loading more photos...
    public static let loadingMore = L10n.tr("Localizable", "CustomPhotoPicker.LoadingMore", fallback: "Loading more photos...")
    /// Photo Access Required
    public static let photoAccessRequired = L10n.tr("Localizable", "CustomPhotoPicker.PhotoAccessRequired", fallback: "Photo Access Required")
    /// %@ Selected
    public static func selected(_ p1: Any) -> String {
      return L10n.tr("Localizable", "CustomPhotoPicker.Selected", String(describing: p1), fallback: "%@ Selected")
    }
    /// Select Photos
    public static let selectPhotos = L10n.tr("Localizable", "CustomPhotoPicker.SelectPhotos", fallback: "Select Photos")
    /// ./Encamera/Components/CustomPhotoPicker.swift
    public static let swipeInstruction = L10n.tr("Localizable", "CustomPhotoPicker.SwipeInstruction", fallback: "Long press & swipe to select multiple photos")
  }
  public enum EnterTheNameOfTheKeyToDeleteItForever {
    /// Enter the name of the key to delete it forever. All media will remain saved.
    public static let allMediaWillRemainSaved = L10n.tr("Localizable", "Enter the name of the key to delete it forever. All media will remain saved.", fallback: "Enter the name of the key to delete it forever. All media will remain saved.")
  }
  public enum Error {
    public enum Alert {
      /// Failed to load file: %@
      public static func failedToLoadFile(_ p1: Any) -> String {
        return L10n.tr("Localizable", "Error.Alert.FailedToLoadFile", String(describing: p1), fallback: "Failed to load file: %@")
      }
      /// Error
      public static let title = L10n.tr("Localizable", "Error.Alert.Title", fallback: "Error")
    }
  }
  public enum ErrorDeletingKey {
    /// ./Encamera/KeyManagement/AlbumDetailView.swift
    public static let pleaseTryAgain = L10n.tr("Localizable", "Error deleting key. Please try again.", fallback: "Error deleting key. Please try again.")
  }
  public enum ErrorDeletingKeyAndAssociatedFiles {
    /// Error deleting key and associated files. Please try again or try to delete files manually via the Files app.
    public static let pleaseTryAgainOrTryToDeleteFilesManuallyViaTheFilesApp = L10n.tr("Localizable", "Error deleting key and associated files. Please try again or try to delete files manually via the Files app.", fallback: "Error deleting key and associated files. Please try again or try to delete files manually via the Files app.")
  }
  public enum FaceIDOnlyAlert {
    /// Cancel
    public static let cancel = L10n.tr("Localizable", "FaceIDOnlyAlert.Cancel", fallback: "Cancel")
    /// Continue
    public static let `continue` = L10n.tr("Localizable", "FaceIDOnlyAlert.Continue", fallback: "Continue")
    /// Switching to Face ID only will clear your current PIN/password. You will only be able to unlock the app using Face ID.
    public static let message = L10n.tr("Localizable", "FaceIDOnlyAlert.Message", fallback: "Switching to Face ID only will clear your current PIN/password. You will only be able to unlock the app using Face ID.")
    /// Clear PIN/Password?
    public static let title = L10n.tr("Localizable", "FaceIDOnlyAlert.Title", fallback: "Clear PIN/Password?")
  }
  public enum FeatureFlagToast {
    /// disabled
    public static let disabled = L10n.tr("Localizable", "FeatureFlagToast.Disabled", fallback: "disabled")
    /// enabled
    public static let enabled = L10n.tr("Localizable", "FeatureFlagToast.Enabled", fallback: "enabled")
    /// Feature Flag Toast - Deep Link Activation
    public static func message(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "FeatureFlagToast.Message", String(describing: p1), String(describing: p2), fallback: "Feature '%@' is now %@")
    }
  }
  public enum FeatureToggles {
    /// Album Selection
    public static let albumSelectionEnabled = L10n.tr("Localizable", "FeatureToggles.AlbumSelectionEnabled", fallback: "Album Selection")
    /// Show album carousel in photo picker
    public static let albumSelectionEnabledDescription = L10n.tr("Localizable", "FeatureToggles.AlbumSelectionEnabledDescription", fallback: "Show album carousel in photo picker")
    /// App Icon Selection
    public static let appIconSelection = L10n.tr("Localizable", "FeatureToggles.AppIconSelection", fallback: "App Icon Selection")
    /// Enable custom app icon selection
    public static let appIconSelectionDescription = L10n.tr("Localizable", "FeatureToggles.AppIconSelectionDescription", fallback: "Enable custom app icon selection")
    /// CloudKit Storage
    public static let cloudKitStorage = L10n.tr("Localizable", "FeatureToggles.CloudKitStorage", fallback: "CloudKit Storage")
    /// Use CloudKit instead of iCloud Drive for cloud albums (in development)
    public static let cloudKitStorageDescription = L10n.tr("Localizable", "FeatureToggles.CloudKitStorageDescription", fallback: "Use CloudKit instead of iCloud Drive for cloud albums (in development)")
    /// Debug Remote Content
    public static let debugRemoteContent = L10n.tr("Localizable", "FeatureToggles.DebugRemoteContent", fallback: "Debug Remote Content")
    /// Enable debugging for remote CMS content
    public static let debugRemoteContentDescription = L10n.tr("Localizable", "FeatureToggles.DebugRemoteContentDescription", fallback: "Enable debugging for remote CMS content")
    /// Detect Duplicates
    public static let detectDuplicates = L10n.tr("Localizable", "FeatureToggles.DetectDuplicates", fallback: "Detect Duplicates")
    /// Enable the find duplicates option in album menus
    public static let detectDuplicatesDescription = L10n.tr("Localizable", "FeatureToggles.DetectDuplicatesDescription", fallback: "Enable the find duplicates option in album menus")
    /// Edit Rotation
    public static let editRotation = L10n.tr("Localizable", "FeatureToggles.EditRotation", fallback: "Edit Rotation")
    /// Enable the edit button in the lightbox to rotate media
    public static let editRotationDescription = L10n.tr("Localizable", "FeatureToggles.EditRotationDescription", fallback: "Enable the edit button in the lightbox to rotate media")
    /// Test RevenueCat
    public static let enableTestRevenueCat = L10n.tr("Localizable", "FeatureToggles.EnableTestRevenueCat", fallback: "Test RevenueCat")
    /// Enable RevenueCat testing mode
    public static let enableTestRevenueCatDescription = L10n.tr("Localizable", "FeatureToggles.EnableTestRevenueCatDescription", fallback: "Enable RevenueCat testing mode")
    /// Enable Video
    public static let enableVideo = L10n.tr("Localizable", "FeatureToggles.EnableVideo", fallback: "Enable Video")
    /// Enable video recording and playback
    public static let enableVideoDescription = L10n.tr("Localizable", "FeatureToggles.EnableVideoDescription", fallback: "Enable video recording and playback")
    /// Encrypted Zip Export
    public static let encryptedZipExport = L10n.tr("Localizable", "FeatureToggles.EncryptedZipExport", fallback: "Encrypted Zip Export")
    /// Enable sharing media as an encrypted zip
    public static let encryptedZipExportDescription = L10n.tr("Localizable", "FeatureToggles.EncryptedZipExportDescription", fallback: "Enable sharing media as an encrypted zip")
    /// Hide Album
    public static let hideAlbum = L10n.tr("Localizable", "FeatureToggles.HideAlbum", fallback: "Hide Album")
    /// Hide album from main view
    public static let hideAlbumDescription = L10n.tr("Localizable", "FeatureToggles.HideAlbumDescription", fallback: "Hide album from main view")
    /// New Paywall
    public static let newPaywall = L10n.tr("Localizable", "FeatureToggles.NewPaywall", fallback: "New Paywall")
    /// Use the redesigned paywall instead of the classic purchase screen
    public static let newPaywallDescription = L10n.tr("Localizable", "FeatureToggles.NewPaywallDescription", fallback: "Use the redesigned paywall instead of the classic purchase screen")
    /// Recovery Phrase
    public static let recoveryPhrase = L10n.tr("Localizable", "FeatureToggles.RecoveryPhrase", fallback: "Recovery Phrase")
    /// Enable recovery phrase feature
    public static let recoveryPhraseDescription = L10n.tr("Localizable", "FeatureToggles.RecoveryPhraseDescription", fallback: "Enable recovery phrase feature")
    /// Changing RevenueCat mode requires restarting the app. Continue?
    public static let revenuecatToggleMessage = L10n.tr("Localizable", "FeatureToggles.RevenuecatToggleMessage", fallback: "Changing RevenueCat mode requires restarting the app. Continue?")
    /// Restart Required
    public static let revenuecatToggleTitle = L10n.tr("Localizable", "FeatureToggles.RevenuecatToggleTitle", fallback: "Restart Required")
    /// 🎨 Design System
    public static let showDesignSystem = L10n.tr("Localizable", "FeatureToggles.ShowDesignSystem", fallback: "🎨 Design System")
    /// Show hidden design system showcase
    public static let showDesignSystemDescription = L10n.tr("Localizable", "FeatureToggles.ShowDesignSystemDescription", fallback: "Show hidden design system showcase")
    /// Show Feature Toggles
    public static let showFeatureToggles = L10n.tr("Localizable", "FeatureToggles.ShowFeatureToggles", fallback: "Show Feature Toggles")
    /// Enable the feature toggles menu in settings
    public static let showFeatureTogglesDescription = L10n.tr("Localizable", "FeatureToggles.ShowFeatureTogglesDescription", fallback: "Enable the feature toggles menu in settings")
    /// Move to Album
    public static let showMoveToAlbum = L10n.tr("Localizable", "FeatureToggles.ShowMoveToAlbum", fallback: "Move to Album")
    /// Enable moving media between albums
    public static let showMoveToAlbumDescription = L10n.tr("Localizable", "FeatureToggles.ShowMoveToAlbumDescription", fallback: "Enable moving media between albums")
    /// ./Encamera/Settings/FeatureTogglesView.swift
    public static let title = L10n.tr("Localizable", "FeatureToggles.Title", fallback: "Feature Toggles")
  }
  public enum FeedbackView {
    /// What could we improve?
    public static let placeholderText = L10n.tr("Localizable", "FeedbackView.PlaceholderText", fallback: "What could we improve?")
    /// Your feedback is really important to us and helps us build a better product. We really appreciate it!
    public static let subheading = L10n.tr("Localizable", "FeedbackView.Subheading", fallback: "Your feedback is really important to us and helps us build a better product. We really appreciate it!")
    /// Submit
    public static let submit = L10n.tr("Localizable", "FeedbackView.Submit", fallback: "Submit")
    /// Thanks!
    public static let thanks = L10n.tr("Localizable", "FeedbackView.Thanks", fallback: "Thanks!")
    /// Leave feedback
    public static let title = L10n.tr("Localizable", "FeedbackView.Title", fallback: "Leave feedback")
    /// We appreciate your feedback
    public static let weAppreciateIt = L10n.tr("Localizable", "FeedbackView.WeAppreciateIt", fallback: "We appreciate your feedback")
  }
  public enum FileLoading {
    /// You are on cellular data. Large files may take longer to download from iCloud.
    public static let cellularWarning = L10n.tr("Localizable", "FileLoading.CellularWarning", fallback: "You are on cellular data. Large files may take longer to download from iCloud.")
    /// Decrypting media
    public static let decrypting = L10n.tr("Localizable", "FileLoading.Decrypting", fallback: "Decrypting media")
    /// Downloading media from iCloud
    public static let downloading = L10n.tr("Localizable", "FileLoading.Downloading", fallback: "Downloading media from iCloud")
    /// STEP %d OF 2
    public static func stepIndicator(_ p1: Int) -> String {
      return L10n.tr("Localizable", "FileLoading.StepIndicator", p1, fallback: "STEP %d OF 2")
    }
    /// STEP %d OF %d
    public static func stepIndicatorGeneric(_ p1: Int, _ p2: Int) -> String {
      return L10n.tr("Localizable", "FileLoading.StepIndicatorGeneric", p1, p2, fallback: "STEP %d OF %d")
    }
  }
  public enum FooterView {
    /// Media Details
    public static let mediaDetails = L10n.tr("Localizable", "FooterView.MediaDetails", fallback: "Media Details")
    public enum Slideshow {
      /// 15 Seconds
      public static let fifteenSeconds = L10n.tr("Localizable", "FooterView.Slideshow.FifteenSeconds", fallback: "15 Seconds")
      /// 5 Seconds
      public static let fiveSeconds = L10n.tr("Localizable", "FooterView.Slideshow.FiveSeconds", fallback: "5 Seconds")
      /// 1 Second
      public static let oneSecond = L10n.tr("Localizable", "FooterView.Slideshow.OneSecond", fallback: "1 Second")
      /// Slideshow Duration
      public static let selectDuration = L10n.tr("Localizable", "FooterView.Slideshow.SelectDuration", fallback: "Slideshow Duration")
      /// 3 Seconds
      public static let threeSeconds = L10n.tr("Localizable", "FooterView.Slideshow.ThreeSeconds", fallback: "3 Seconds")
    }
  }
  public enum GalleryView {
    /// Album cover set
    public static let albumCoverSetToast = L10n.tr("Localizable", "GalleryView.AlbumCoverSetToast", fallback: "Album cover set")
    /// Make Album Cover
    public static let makeAlbumCover = L10n.tr("Localizable", "GalleryView.MakeAlbumCover", fallback: "Make Album Cover")
    /// Live Photo - Hold to View
    public static let playLivePhoto = L10n.tr("Localizable", "GalleryView.PlayLivePhoto", fallback: "Live Photo - Hold to View")
  }
  public enum GlobalImportProgress {
    /// Delete from Photo Library?
    public static let deleteFromPhotoLibraryAlert = L10n.tr("Localizable", "GlobalImportProgress.DeleteFromPhotoLibraryAlert", fallback: "Delete from Photo Library?")
    /// This will delete all imported photos from your Photo Library.
    public static let deleteFromPhotoLibraryMessage = L10n.tr("Localizable", "GlobalImportProgress.DeleteFromPhotoLibraryMessage", fallback: "This will delete all imported photos from your Photo Library.")
    /// Import canceled
    public static let importCanceled = L10n.tr("Localizable", "GlobalImportProgress.ImportCanceled", fallback: "Import canceled")
    /// ./Encamera/Components/ImportProgress/GlobalImportProgressView.swift
    public static let importCompleted = L10n.tr("Localizable", "GlobalImportProgress.ImportCompleted", fallback: "Import completed")
    /// Importing %@ batches
    public static func importingBatches(_ p1: Any) -> String {
      return L10n.tr("Localizable", "GlobalImportProgress.ImportingBatches", String(describing: p1), fallback: "Importing %@ batches")
    }
    /// Importing %@ of %@
    public static func importingProgress(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "GlobalImportProgress.ImportingProgress", String(describing: p1), String(describing: p2), fallback: "Importing %@ of %@")
    }
    /// Import stopped
    public static let importStopped = L10n.tr("Localizable", "GlobalImportProgress.ImportStopped", fallback: "Import stopped")
    /// No active imports
    public static let noActiveImports = L10n.tr("Localizable", "GlobalImportProgress.NoActiveImports", fallback: "No active imports")
    /// Photos deleted
    public static let photosDeleted = L10n.tr("Localizable", "GlobalImportProgress.PhotosDeleted", fallback: "Photos deleted")
    /// Preparing %@ of %@ files...
    public static func preparingFiles(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "GlobalImportProgress.PreparingFiles", String(describing: p1), String(describing: p2), fallback: "Preparing %@ of %@ files...")
    }
    /// Preparing files...
    public static let preparingProgress = L10n.tr("Localizable", "GlobalImportProgress.PreparingProgress", fallback: "Preparing files...")
    /// Remaining
    public static let remaining = L10n.tr("Localizable", "GlobalImportProgress.Remaining", fallback: "Remaining")
  }
  public enum GuidedSync {
    /// On your other device, open Encamera and turn on iCloud Multi-Device Mode in Settings. Your key will sync to this device automatically.
    public static let body = L10n.tr("Localizable", "GuidedSync.Body", fallback: "On your other device, open Encamera and turn on iCloud Multi-Device Mode in Settings. Your key will sync to this device automatically.")
    /// On %@, open Encamera and turn on iCloud Multi-Device Mode in Settings. Your key will sync to this device automatically.
    public static func bodyNamed(_ p1: Any) -> String {
      return L10n.tr("Localizable", "GuidedSync.BodyNamed", String(describing: p1), fallback: "On %@, open Encamera and turn on iCloud Multi-Device Mode in Settings. Your key will sync to this device automatically.")
    }
    /// Continue
    public static let `continue` = L10n.tr("Localizable", "GuidedSync.Continue", fallback: "Continue")
    /// Enter key phrase instead
    public static let enterManually = L10n.tr("Localizable", "GuidedSync.EnterManually", fallback: "Enter key phrase instead")
    /// A key arrived from another device, but it isn't the one your photos here need. Enter your key phrase instead, or keep waiting for the right device to sync.
    public static let mismatchBody = L10n.tr("Localizable", "GuidedSync.MismatchBody", fallback: "A key arrived from another device, but it isn't the one your photos here need. Enter your key phrase instead, or keep waiting for the right device to sync.")
    /// That's a different key
    public static let mismatchTitle = L10n.tr("Localizable", "GuidedSync.MismatchTitle", fallback: "That's a different key")
    /// Keep waiting
    public static let retry = L10n.tr("Localizable", "GuidedSync.Retry", fallback: "Keep waiting")
    /// Your key arrived from your other device. You're all set to continue on this device.
    public static let successBody = L10n.tr("Localizable", "GuidedSync.SuccessBody", fallback: "Your key arrived from your other device. You're all set to continue on this device.")
    /// Key synced
    public static let successTitle = L10n.tr("Localizable", "GuidedSync.SuccessTitle", fallback: "Key synced")
    /// Your key hasn't arrived yet. Make sure iCloud Keychain is turned on: check Settings → iCloud → Passwords & Keychain on both devices, then try again.
    public static let timeoutBody = L10n.tr("Localizable", "GuidedSync.TimeoutBody", fallback: "Your key hasn't arrived yet. Make sure iCloud Keychain is turned on: check Settings → iCloud → Passwords & Keychain on both devices, then try again.")
    /// Still waiting for your key
    public static let timeoutTitle = L10n.tr("Localizable", "GuidedSync.TimeoutTitle", fallback: "Still waiting for your key")
    /// ./Encamera/Onboarding/OnboardingGuidedSyncView.swift - Guided flip-the-switch flow: wait for the key to arrive via iCloud Keychain (ENC-93)
    public static let title = L10n.tr("Localizable", "GuidedSync.Title", fallback: "Turn on Multi-Device Mode")
    /// Waiting for your key to arrive…
    public static let waiting = L10n.tr("Localizable", "GuidedSync.Waiting", fallback: "Waiting for your key to arrive…")
  }
  public enum HideAlbumsTutorial {
    /// Keep your albums private
    public static let heading1 = L10n.tr("Localizable", "HideAlbumsTutorial.Heading1", fallback: "Keep your albums private")
    /// Access hidden albums
    public static let heading2 = L10n.tr("Localizable", "HideAlbumsTutorial.Heading2", fallback: "Access hidden albums")
    /// Remember album names
    public static let heading3 = L10n.tr("Localizable", "HideAlbumsTutorial.Heading3", fallback: "Remember album names")
    /// Hide an album
    public static let heading4 = L10n.tr("Localizable", "HideAlbumsTutorial.Heading4", fallback: "Hide an album")
    /// Encamera allows you to hide albums from the main view for extra privacy.
    public static let subheading1 = L10n.tr("Localizable", "HideAlbumsTutorial.Subheading1", fallback: "Encamera allows you to hide albums from the main view for extra privacy.")
    /// To access a hidden album, simply search for its name in the search bar.
    public static let subheading2 = L10n.tr("Localizable", "HideAlbumsTutorial.Subheading2", fallback: "To access a hidden album, simply search for its name in the search bar.")
    /// Make sure to remember the names of your hidden albums, as they won't appear in your album list.
    public static let subheading3 = L10n.tr("Localizable", "HideAlbumsTutorial.Subheading3", fallback: "Make sure to remember the names of your hidden albums, as they won't appear in your album list.")
    /// To hide an album, open it and tap the three dots menu, then select 'Hide Album'.
    public static let subheading4 = L10n.tr("Localizable", "HideAlbumsTutorial.Subheading4", fallback: "To hide an album, open it and tap the three dots menu, then select 'Hide Album'.")
    /// Hide Albums Tutorial
    public static let title = L10n.tr("Localizable", "HideAlbumsTutorial.Title", fallback: "Hide Albums")
  }
  public enum HideImageTutorial {
    /// Hide Image Tutorial
    public static let headingText1 = L10n.tr("Localizable", "HideImageTutorial.HeadingText1", fallback: "Hide Your Albums")
    /// Remember the Name
    public static let headingText2 = L10n.tr("Localizable", "HideImageTutorial.HeadingText2", fallback: "Remember the Name")
    /// View Hidden Albums
    public static let headingText3 = L10n.tr("Localizable", "HideImageTutorial.HeadingText3", fallback: "View Hidden Albums")
    /// Access the Albums
    public static let headingText4 = L10n.tr("Localizable", "HideImageTutorial.HeadingText4", fallback: "Access the Albums")
    /// Tap the hide icon to make your albums invisible. Hidden albums are completely secure and won't appear in your list.
    public static let subheadingText1 = L10n.tr("Localizable", "HideImageTutorial.SubheadingText1", fallback: "Tap the hide icon to make your albums invisible. Hidden albums are completely secure and won't appear in your list.")
    /// The album name is your key to access it later. Choose a name you'll remember or keep it noted somewhere safe.
    public static let subheadingText2 = L10n.tr("Localizable", "HideImageTutorial.SubheadingText2", fallback: "The album name is your key to access it later. Choose a name you'll remember or keep it noted somewhere safe.")
    /// Need a quick overview? Long press the "Hide Albums" section to see a list of all your hidden albums.
    public static let subheadingText3 = L10n.tr("Localizable", "HideImageTutorial.SubheadingText3", fallback: "Need a quick overview? Long press the \"Hide Albums\" section to see a list of all your hidden albums.")
    /// To unhide an album, create a new album with the exact same name. Your hidden albums will instantly reappear.
    public static let subheadingText4 = L10n.tr("Localizable", "HideImageTutorial.SubheadingText4", fallback: "To unhide an album, create a new album with the exact same name. Your hidden albums will instantly reappear.")
  }
  public enum ICloudError {
    /// Could not download '%@' from iCloud: %@
    public static func downloadFailed(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "ICloudError.DownloadFailed", String(describing: p1), String(describing: p2), fallback: "Could not download '%@' from iCloud: %@")
    }
    /// Could not download '%@' from iCloud. Please check your internet connection and iCloud settings.
    public static func downloadFailedGeneric(_ p1: Any) -> String {
      return L10n.tr("Localizable", "ICloudError.DownloadFailedGeneric", String(describing: p1), fallback: "Could not download '%@' from iCloud. Please check your internet connection and iCloud settings.")
    }
    /// File '%@' is still downloading from iCloud. Please wait.
    public static func downloadInProgress(_ p1: Any) -> String {
      return L10n.tr("Localizable", "ICloudError.DownloadInProgress", String(describing: p1), fallback: "File '%@' is still downloading from iCloud. Please wait.")
    }
    /// iCloud download timed out. Please check your internet connection and try again.
    public static let downloadTimeout = L10n.tr("Localizable", "ICloudError.DownloadTimeout", fallback: "iCloud download timed out. Please check your internet connection and try again.")
    /// ./Encamera/ImageViewing/MediaViewingError.swift - iCloud Error Messages
    public static let fileNotDownloaded = L10n.tr("Localizable", "ICloudError.FileNotDownloaded", fallback: "This file is stored in iCloud and needs to be downloaded. Please check your internet connection and try again.")
    /// This file is stored in iCloud and could not be downloaded. Connect to Wi-Fi and try again.
    public static let notAvailableCellular = L10n.tr("Localizable", "ICloudError.NotAvailableCellular", fallback: "This file is stored in iCloud and could not be downloaded. Connect to Wi-Fi and try again.")
    /// This file is stored in iCloud and could not be downloaded. Connect to the internet and try again.
    public static let notAvailableNoConnection = L10n.tr("Localizable", "ICloudError.NotAvailableNoConnection", fallback: "This file is stored in iCloud and could not be downloaded. Connect to the internet and try again.")
    /// This file is stored in iCloud and could not be downloaded. Check your iCloud connection and try again.
    public static let notAvailableWiFi = L10n.tr("Localizable", "ICloudError.NotAvailableWiFi", fallback: "This file is stored in iCloud and could not be downloaded. Check your iCloud connection and try again.")
  }
  public enum ICloudStatus {
    /// ./Encamera/Components/iCloudSyncStatusIndicator.swift - Directory Sync Status
    public static let allSynced = L10n.tr("Localizable", "ICloudStatus.AllSynced", fallback: "All files downloaded")
    /// File is downloaded.
    public static let downloaded = L10n.tr("Localizable", "ICloudStatus.Downloaded", fallback: "File is downloaded.")
    /// Download failed: %@
    public static func downloadFailed(_ p1: Any) -> String {
      return L10n.tr("Localizable", "ICloudStatus.DownloadFailed", String(describing: p1), fallback: "Download failed: %@")
    }
    /// Download from iCloud failed.
    public static let downloadFailedUnknown = L10n.tr("Localizable", "ICloudStatus.DownloadFailedUnknown", fallback: "Download from iCloud failed.")
    /// Downloading from iCloud: %d%%
    public static func downloading(_ p1: Int) -> String {
      return L10n.tr("Localizable", "ICloudStatus.Downloading", p1, fallback: "Downloading from iCloud: %d%%")
    }
    /// No files in iCloud
    public static let noFiles = L10n.tr("Localizable", "ICloudStatus.NoFiles", fallback: "No files in iCloud")
    /// File is stored in iCloud and needs to be downloaded.
    public static let notDownloaded = L10n.tr("Localizable", "ICloudStatus.NotDownloaded", fallback: "File is stored in iCloud and needs to be downloaded.")
    /// ./EncameraCore/Utils/iCloudFileStatusUtil.swift
    public static let notICloudFile = L10n.tr("Localizable", "ICloudStatus.NotICloudFile", fallback: "This file is stored locally.")
    /// %d files need download
    public static func pendingDownload(_ p1: Int) -> String {
      return L10n.tr("Localizable", "ICloudStatus.PendingDownload", p1, fallback: "%d files need download")
    }
    /// Downloading %d of %d files
    public static func syncing(_ p1: Int, _ p2: Int) -> String {
      return L10n.tr("Localizable", "ICloudStatus.Syncing", p1, p2, fallback: "Downloading %d of %d files")
    }
    /// Tap to download
    public static let tapToDownload = L10n.tr("Localizable", "ICloudStatus.TapToDownload", fallback: "Tap to download")
  }
  public enum ImportKeyPhrase {
    public enum Confirm {
      /// Replace
      public static let action = L10n.tr("Localizable", "ImportKeyPhrase.Confirm.Action", fallback: "Replace")
      /// This key phrase will become the one Encamera uses for new media. Your current key phrase is kept, so everything already encrypted with it stays readable.
      public static let message = L10n.tr("Localizable", "ImportKeyPhrase.Confirm.Message", fallback: "This key phrase will become the one Encamera uses for new media. Your current key phrase is kept, so everything already encrypted with it stays readable.")
      /// Replace Key Phrase?
      public static let title = L10n.tr("Localizable", "ImportKeyPhrase.Confirm.Title", fallback: "Replace Key Phrase?")
    }
    public enum RestartRequired {
      /// After changing your key, the app will restart.
      public static let message = L10n.tr("Localizable", "ImportKeyPhrase.RestartRequired.Message", fallback: "After changing your key, the app will restart.")
      /// Restart Required
      public static let title = L10n.tr("Localizable", "ImportKeyPhrase.RestartRequired.Title", fallback: "Restart Required")
    }
  }
  public enum ImportTaskDetailsView {
    /// Clear All
    public static let clearAll = L10n.tr("Localizable", "ImportTaskDetailsView.ClearAll", fallback: "Clear All")
    /// Done
    public static let done = L10n.tr("Localizable", "ImportTaskDetailsView.Done", fallback: "Done")
    /// ./Encamera/Components/ImportProgress/ImportTaskDetailsView.swift
    public static let title = L10n.tr("Localizable", "ImportTaskDetailsView.Title", fallback: "Import Tasks")
  }
  public enum KeyCopiedToClipboard {
    /// Key copied to clipboard. Store this in a password manager or other secure place.
    public static let storeThisInAPasswordManagerOrOtherSecurePlace = L10n.tr("Localizable", "Key copied to clipboard. Store this in a password manager or other secure place.", fallback: "Key copied to clipboard. Store this in a password manager or other secure place.")
  }
  public enum KeyEntry {
    /// That's not the key these photos need. You entered key %@, but they need key %@.
    public static func fingerprintMismatch(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "KeyEntry.FingerprintMismatch", String(describing: p1), String(describing: p2), fallback: "That's not the key these photos need. You entered key %@, but they need key %@.")
    }
    /// Key saved. We'll verify it against your photos when they load.
    public static let offlineAccepted = L10n.tr("Localizable", "KeyEntry.OfflineAccepted", fallback: "Key saved. We'll verify it against your photos when they load.")
    /// Enter the key phrase for your Encamera account. Your existing photos are encrypted with it.
    public static let prompt = L10n.tr("Localizable", "KeyEntry.Prompt", fallback: "Enter the key phrase for your Encamera account. Your existing photos are encrypted with it.")
    /// Enter your key phrase. We couldn't reach your existing photos to check it now — we'll verify it when they load.
    public static let promptUnknown = L10n.tr("Localizable", "KeyEntry.PromptUnknown", fallback: "Enter your key phrase. We couldn't reach your existing photos to check it now — we'll verify it when they load.")
    /// Enter the key phrase for key %@. Your existing photos are encrypted with it.
    public static func promptWithFingerprint(_ p1: Any) -> String {
      return L10n.tr("Localizable", "KeyEntry.PromptWithFingerprint", String(describing: p1), fallback: "Enter the key phrase for key %@. Your existing photos are encrypted with it.")
    }
    /// Verify and continue
    public static let submit = L10n.tr("Localizable", "KeyEntry.Submit", fallback: "Verify and continue")
    /// ./Encamera/Onboarding/OnboardingKeyEntryView.swift - Manual key-phrase entry with fingerprint validation (ENC-92)
    public static let title = L10n.tr("Localizable", "KeyEntry.Title", fallback: "Enter your key phrase")
    /// Checking your key…
    public static let verifying = L10n.tr("Localizable", "KeyEntry.Verifying", fallback: "Checking your key…")
  }
  public enum KeyMissing {
    /// another device
    public static let anotherDevice = L10n.tr("Localizable", "KeyMissing.AnotherDevice", fallback: "another device")
    /// iCloud key backup was turned off from %@, which removes the key from all other devices.
    public static func disabledFromDevice(_ p1: Any) -> String {
      return L10n.tr("Localizable", "KeyMissing.DisabledFromDevice", String(describing: p1), fallback: "iCloud key backup was turned off from %@, which removes the key from all other devices.")
    }
    /// iCloud key backup was turned off from %@ on %@, which removes the key from all other devices.
    public static func disabledFromDeviceOn(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "KeyMissing.DisabledFromDeviceOn", String(describing: p1), String(describing: p2), fallback: "iCloud key backup was turned off from %@ on %@, which removes the key from all other devices.")
    }
    /// Enter Key Phrase
    public static let enterKeyPhrase = L10n.tr("Localizable", "KeyMissing.EnterKeyPhrase", fallback: "Enter Key Phrase")
    /// Start fresh on this device
    public static let startFresh = L10n.tr("Localizable", "KeyMissing.StartFresh", fallback: "Start fresh on this device")
    /// Your encryption key isn't available on this device, so existing photos can't be decrypted.
    public static let subtitle = L10n.tr("Localizable", "KeyMissing.Subtitle", fallback: "Your encryption key isn't available on this device, so existing photos can't be decrypted.")
    /// ./Encamera/Components/KeyMissingView.swift - No encryption key on this device
    public static let title = L10n.tr("Localizable", "KeyMissing.Title", fallback: "No encryption key on this device")
  }
  public enum KeyPhrase {
    /// My Key Has Been Stored
    public static let continueButton = L10n.tr("Localizable", "KeyPhrase.ContinueButton", fallback: "My Key Has Been Stored")
    /// Copy Key Phrase
    public static let copyButton = L10n.tr("Localizable", "KeyPhrase.CopyButton", fallback: "Copy Key Phrase")
    /// This is your unique encryption key phrase. If you lose this and get a new phone, you will never be able to access your encrypted photos and videos again. Please save it in a safe place.
    public static let subtitle = L10n.tr("Localizable", "KeyPhrase.Subtitle", fallback: "This is your unique encryption key phrase. If you lose this and get a new phone, you will never be able to access your encrypted photos and videos again. Please save it in a safe place.")
    /// Key Phrase Display Screen
    public static let title = L10n.tr("Localizable", "KeyPhrase.Title", fallback: "Your Encryption Key Phrase")
  }
  public enum Lightbox {
    /// ./Encamera/Lightbox/LightboxController.swift - Edit Mode
    public static let edit = L10n.tr("Localizable", "Lightbox.Edit", fallback: "Edit")
    public enum Edit {
      /// Edit saved
      public static let completed = L10n.tr("Localizable", "Lightbox.Edit.Completed", fallback: "Edit saved")
      /// Decrypting...
      public static let decrypting = L10n.tr("Localizable", "Lightbox.Edit.Decrypting", fallback: "Decrypting...")
      /// Encrypting...
      public static let encrypting = L10n.tr("Localizable", "Lightbox.Edit.Encrypting", fallback: "Encrypting...")
      /// Rotating...
      public static let rotating = L10n.tr("Localizable", "Lightbox.Edit.Rotating", fallback: "Rotating...")
    }
  }
  public enum MainHomeView {
    /// ./Encamera/MainHomeView/MainHomeView.swift
    public static let backupEncryptionKey = L10n.tr("Localizable", "MainHomeView.BackupEncryptionKey", fallback: "Back up your Encryption Key")
    /// Your photos are protected with a unique encryption key. This is the only way to decrypt your images if you switch devices or reinstall the app.
    public static let keyBackupExplanation = L10n.tr("Localizable", "MainHomeView.KeyBackupExplanation", fallback: "Your photos are protected with a unique encryption key. This is the only way to decrypt your images if you switch devices or reinstall the app.")
    /// You will not be able to view your media without this key.
    public static let keyBackupWarning = L10n.tr("Localizable", "MainHomeView.KeyBackupWarning", fallback: "You will not be able to view your media without this key.")
    /// View the Key
    public static let viewTheKey = L10n.tr("Localizable", "MainHomeView.ViewTheKey", fallback: "View the Key")
    public enum TabBar {
      /// Camera
      public static let camera = L10n.tr("Localizable", "MainHomeView.TabBar.Camera", fallback: "Camera")
    }
  }
  public enum MediaInfo {
    /// Additional Details
    public static let additionalDetails = L10n.tr("Localizable", "MediaInfo.AdditionalDetails", fallback: "Additional Details")
    /// Burst Photo
    public static let burstPhoto = L10n.tr("Localizable", "MediaInfo.BurstPhoto", fallback: "Burst Photo")
    /// Codec
    public static let codec = L10n.tr("Localizable", "MediaInfo.Codec", fallback: "Codec")
    /// Duration
    public static let duration = L10n.tr("Localizable", "MediaInfo.Duration", fallback: "Duration")
    /// Encrypted
    public static let encrypted = L10n.tr("Localizable", "MediaInfo.Encrypted", fallback: "Encrypted")
    /// Original File Name
    public static let filename = L10n.tr("Localizable", "MediaInfo.Filename", fallback: "Original File Name")
    /// Frame Rate
    public static let frameRate = L10n.tr("Localizable", "MediaInfo.FrameRate", fallback: "Frame Rate")
    /// Key Fingerprint
    public static let keyFingerprint = L10n.tr("Localizable", "MediaInfo.KeyFingerprint", fallback: "Key Fingerprint")
    /// Metadata Not Available
    public static let metadataNotAvailable = L10n.tr("Localizable", "MediaInfo.MetadataNotAvailable", fallback: "Metadata Not Available")
    /// Screenshot
    public static let screenshot = L10n.tr("Localizable", "MediaInfo.Screenshot", fallback: "Screenshot")
    /// Type
    public static let type = L10n.tr("Localizable", "MediaInfo.Type", fallback: "Type")
    /// ./Encamera/Lightbox/Views/MediaInfoDetailView.swift - Media Info
    public static let unknownDevice = L10n.tr("Localizable", "MediaInfo.UnknownDevice", fallback: "Unknown Device")
  }
  public enum MediaSelectionTray {
    /// Selected
    public static let itemSelected = L10n.tr("Localizable", "MediaSelectionTray.ItemSelected", fallback: "Selected")
    /// Move
    public static let moveMedia = L10n.tr("Localizable", "MediaSelectionTray.MoveMedia", fallback: "Move")
    /// ./Encamera/AlbumManagement/MediaSelectionTray.swift
    public static let moveToAlbum = L10n.tr("Localizable", "MediaSelectionTray.MoveToAlbum", fallback: "Move to Album")
    /// Select Media
    public static let selectMedia = L10n.tr("Localizable", "MediaSelectionTray.SelectMedia", fallback: "Select Media")
  }
  public enum MissingKey {
    /// Key added. Your media should open now.
    public static let added = L10n.tr("Localizable", "MissingKey.Added", fallback: "Key added. Your media should open now.")
    /// Add this key
    public static let addKey = L10n.tr("Localizable", "MissingKey.AddKey", fallback: "Add this key")
    /// Missing Key
    public static let albumTitle = L10n.tr("Localizable", "MissingKey.AlbumTitle", fallback: "Missing Key")
    /// Enter the key phrase for key %@. It will only be used to open existing media — new photos keep using this device's key.
    public static func addKeyPrompt(_ p1: Any) -> String {
      return L10n.tr("Localizable", "MissingKey.AddKeyPrompt", String(describing: p1), fallback: "Enter the key phrase for key %@. It will only be used to open existing media — new photos keep using this device's key.")
    }
    /// Enter the key phrase for the key this media needs. It will only be used to open existing media — new photos keep using this device's key.
    public static let addKeyPromptUnknown = L10n.tr("Localizable", "MissingKey.AddKeyPromptUnknown", fallback: "Enter the key phrase for the key this media needs. It will only be used to open existing media — new photos keep using this device's key.")
    /// Add a key
    public static let addKeyTitle = L10n.tr("Localizable", "MissingKey.AddKeyTitle", fallback: "Add a key")
    /// You already have that key on this device.
    public static let alreadyHaveKey = L10n.tr("Localizable", "MissingKey.AlreadyHaveKey", fallback: "You already have that key on this device.")
    /// This key phrase couldn't be checked because none of this album's media has downloaded yet. Wait for the download to finish and try again.
    public static let couldNotVerify = L10n.tr("Localizable", "MissingKey.CouldNotVerify", fallback: "This key phrase couldn't be checked because none of this album's media has downloaded yet. Wait for the download to finish and try again.")
    /// %d album(s) can't be shown because their key isn't on this device.
    public static func lockedAlbums(_ p1: Int) -> String {
      return L10n.tr("Localizable", "MissingKey.LockedAlbums", p1, fallback: "%d album(s) can't be shown because their key isn't on this device.")
    }
    /// Missing key
    public static let shortLabel = L10n.tr("Localizable", "MissingKey.ShortLabel", fallback: "Missing key")
    /// It was encrypted with a key that isn't on this device.
    public static let subtitleUnknown = L10n.tr("Localizable", "MissingKey.SubtitleUnknown", fallback: "It was encrypted with a key that isn't on this device.")
    /// It was encrypted with key %@, which isn't on this device.
    public static func subtitleWithFingerprint(_ p1: Any) -> String {
      return L10n.tr("Localizable", "MissingKey.SubtitleWithFingerprint", String(describing: p1), fallback: "It was encrypted with key %@, which isn't on this device.")
    }
    /// ENC-99 - Media encrypted with a key this device does not hold (placeholder copy; design in ENC-103)
    public static let title = L10n.tr("Localizable", "MissingKey.Title", fallback: "This photo needs a different key")
    /// That key phrase is for key %@, but this media needs key %@.
    public static func wrongKey(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "MissingKey.WrongKey", String(describing: p1), String(describing: p2), fallback: "That key phrase is for key %@, but this media needs key %@.")
    }
    /// That key phrase doesn't open this media.
    public static let wrongKeyUnknown = L10n.tr("Localizable", "MissingKey.WrongKeyUnknown", fallback: "That key phrase doesn't open this media.")
  }
  public enum Notification {
    /// Unknown notification identifier
    public static let unknownIdentifier = L10n.tr("Localizable", "Notification.UnknownIdentifier", fallback: "Unknown notification identifier")
    public enum ImageSaveReminder {
      /// Hope you like Encamera - This is why we need you to help us with a review. Tap here!
      public static let body = L10n.tr("Localizable", "Notification.ImageSaveReminder.Body", fallback: "Hope you like Encamera - This is why we need you to help us with a review. Tap here!")
      /// We would like your support 🙏
      public static let title = L10n.tr("Localizable", "Notification.ImageSaveReminder.Title", fallback: "We would like your support 🙏")
    }
    public enum ImageSecurityReminder {
      /// You can also save videos to your albums, not only images. Try it now and secure some!
      public static let body = L10n.tr("Localizable", "Notification.ImageSecurityReminder.Body", fallback: "You can also save videos to your albums, not only images. Try it now and secure some!")
      /// Did you know? 🤔
      public static let title = L10n.tr("Localizable", "Notification.ImageSecurityReminder.Title", fallback: "Did you know? 🤔")
    }
    public enum ImportImages {
      /// Prompting user to import more images for security.
      public static let prompt = L10n.tr("Localizable", "Notification.ImportImages.Prompt", fallback: "Prompting user to import more images for security.")
    }
    public enum InactiveUserReminder {
      /// Don't forget to secure more images by adding them to your album. Import now!
      public static let body = L10n.tr("Localizable", "Notification.InactiveUserReminder.Body", fallback: "Don't forget to secure more images by adding them to your album. Import now!")
      /// Your images might be at risk 🚨
      public static let title = L10n.tr("Localizable", "Notification.InactiveUserReminder.Title", fallback: "Your images might be at risk 🚨")
    }
    public enum Permission {
      /// Error requesting local notification permissions: %@
      public static func error(_ p1: Any) -> String {
        return L10n.tr("Localizable", "Notification.Permission.Error", String(describing: p1), fallback: "Error requesting local notification permissions: %@")
      }
      /// Local notification permissions granted.
      public static let granted = L10n.tr("Localizable", "Notification.Permission.Granted", fallback: "Local notification permissions granted.")
      /// Error requesting remote notification permissions: %@
      public static func remoteError(_ p1: Any) -> String {
        return L10n.tr("Localizable", "Notification.Permission.RemoteError", String(describing: p1), fallback: "Error requesting remote notification permissions: %@")
      }
    }
    public enum PremiumPage {
      /// Navigating to the premium plan purchase page.
      public static let navigation = L10n.tr("Localizable", "Notification.PremiumPage.Navigation", fallback: "Navigating to the premium plan purchase page.")
    }
    public enum PremiumReminder {
      /// Use code 'ENCAMERA20' to get a 20%% discount on any plan. Hurry up!
      public static let body = L10n.tr("Localizable", "Notification.PremiumReminder.Body", fallback: "Use code 'ENCAMERA20' to get a 20%% discount on any plan. Hurry up!")
      /// 20%% Discount - Limited time 📅
      public static let title = L10n.tr("Localizable", "Notification.PremiumReminder.Title", fallback: "20%% Discount - Limited time 📅")
    }
    public enum ReviewPage {
      /// Navigating to the review submission page.
      public static let navigation = L10n.tr("Localizable", "Notification.ReviewPage.Navigation", fallback: "Navigating to the review submission page.")
    }
    public enum Scheduling {
      /// Error scheduling notification: %@
      public static func error(_ p1: Any) -> String {
        return L10n.tr("Localizable", "Notification.Scheduling.Error", String(describing: p1), fallback: "Error scheduling notification: %@")
      }
    }
    public enum VideoSave {
      /// Showing educational content on how to save videos.
      public static let educationalContent = L10n.tr("Localizable", "Notification.VideoSave.EducationalContent", fallback: "Showing educational content on how to save videos.")
    }
    public enum WidgetReminder {
      /// Don't forget to add the widget on the lock screen and take images quickly. See how!
      public static let body = L10n.tr("Localizable", "Notification.WidgetReminder.Body", fallback: "Don't forget to add the widget on the lock screen and take images quickly. See how!")
      /// Take directly encrypted photos 📸
      public static let title = L10n.tr("Localizable", "Notification.WidgetReminder.Title", fallback: "Take directly encrypted photos 📸")
    }
    public enum WidgetSetup {
      /// Guiding user to add a widget to the lock screen.
      public static let guidance = L10n.tr("Localizable", "Notification.WidgetSetup.Guidance", fallback: "Guiding user to add a widget to the lock screen.")
    }
  }
  public enum NotificationBanner {
    public enum LeaveAReview {
      /// If you like Encamera, help us out with a review!
      public static let body = L10n.tr("Localizable", "NotificationBanner.LeaveAReview.Body", fallback: "If you like Encamera, help us out with a review!")
      /// We need your help!
      public static let title = L10n.tr("Localizable", "NotificationBanner.LeaveAReview.Title", fallback: "We need your help!")
    }
    public enum Reddit {
      /// Join the Encamera subreddit to follow the latest and give feedback
      public static let body = L10n.tr("Localizable", "NotificationBanner.Reddit.Body", fallback: "Join the Encamera subreddit to follow the latest and give feedback")
      /// Join Subreddit
      public static let button = L10n.tr("Localizable", "NotificationBanner.Reddit.Button", fallback: "Join Subreddit")
      /// Are you on Reddit?
      public static let title = L10n.tr("Localizable", "NotificationBanner.Reddit.Title", fallback: "Are you on Reddit?")
    }
  }
  public enum Onboarding {
    /// I already use Encamera on another device
    public static let alreadyUseEncamera = L10n.tr("Localizable", "Onboarding.AlreadyUseEncamera", fallback: "I already use Encamera on another device")
    public enum MultiDeviceMode {
      /// Your key and passcode can travel with you through your iCloud Keychain, so Encamera works on your iPad and your other Apple devices.
      public static let body = L10n.tr("Localizable", "Onboarding.MultiDeviceMode.Body", fallback: "Your key and passcode can travel with you through your iCloud Keychain, so Encamera works on your iPad and your other Apple devices.")
      /// Turn On
      public static let confirmTurnOn = L10n.tr("Localizable", "Onboarding.MultiDeviceMode.ConfirmTurnOn", fallback: "Turn On")
      /// Turn On Multi-Device Mode
      public static let enableButton = L10n.tr("Localizable", "Onboarding.MultiDeviceMode.EnableButton", fallback: "Turn On Multi-Device Mode")
      /// Not Now
      public static let skipButton = L10n.tr("Localizable", "Onboarding.MultiDeviceMode.SkipButton", fallback: "Not Now")
      /// ./Encamera/Onboarding/OnboardingHostingView.swift - iCloud Multi-Device Mode opt-in during onboarding (ENC-95). Default off; explicit tap required.
      public static let title = L10n.tr("Localizable", "Onboarding.MultiDeviceMode.Title", fallback: "Use Encamera on all your devices")
    }
    public enum RestorePurchases {
      /// Check your internet connection and try restoring again. You can continue setting up Encamera without it.
      public static let networkErrorMessage = L10n.tr("Localizable", "Onboarding.RestorePurchases.NetworkErrorMessage", fallback: "Check your internet connection and try restoring again. You can continue setting up Encamera without it.")
      /// Couldn't reach the App Store
      public static let networkErrorTitle = L10n.tr("Localizable", "Onboarding.RestorePurchases.NetworkErrorTitle", fallback: "Couldn't reach the App Store")
      /// We couldn't find any previous purchases on your Apple ID. You can continue setting up Encamera and subscribe any time.
      public static let noPurchasesMessage = L10n.tr("Localizable", "Onboarding.RestorePurchases.NoPurchasesMessage", fallback: "We couldn't find any previous purchases on your Apple ID. You can continue setting up Encamera and subscribe any time.")
      /// ./Encamera/Onboarding/OnboardingHostingView.swift - Restore Purchases during onboarding (ENC-96). Three distinct failure modes.
      public static let noPurchasesTitle = L10n.tr("Localizable", "Onboarding.RestorePurchases.NoPurchasesTitle", fallback: "No purchases to restore")
      /// Sign in to the App Store in Settings, then try restoring again. You can continue setting up Encamera in the meantime.
      public static let notSignedInMessage = L10n.tr("Localizable", "Onboarding.RestorePurchases.NotSignedInMessage", fallback: "Sign in to the App Store in Settings, then try restoring again. You can continue setting up Encamera in the meantime.")
      /// Not signed in to the App Store
      public static let notSignedInTitle = L10n.tr("Localizable", "Onboarding.RestorePurchases.NotSignedInTitle", fallback: "Not signed in to the App Store")
    }
  }
  public enum OnboardingCarousel {
    /// Your memories, fully protected
    public static let headingText1 = L10n.tr("Localizable", "OnboardingCarousel.HeadingText1", fallback: "Your memories, fully protected")
    /// Only you hold the encryption key
    public static let headingText2 = L10n.tr("Localizable", "OnboardingCarousel.HeadingText2", fallback: "Only you hold the encryption key")
    /// No accounts. No profiling. No ads.
    public static let headingText3 = L10n.tr("Localizable", "OnboardingCarousel.HeadingText3", fallback: "No accounts. No profiling. No ads.")
    /// We encrypt every picture and video instantly. No one else can see them, not even us.
    public static let subheadingText1 = L10n.tr("Localizable", "OnboardingCarousel.SubheadingText1", fallback: "We encrypt every picture and video instantly. No one else can see them, not even us.")
    /// Your albums are locked with your unique key and stored safely on your device or iCloud.
    public static let subheadingText2 = L10n.tr("Localizable", "OnboardingCarousel.SubheadingText2", fallback: "Your albums are locked with your unique key and stored safely on your device or iCloud.")
    /// Encamera never collects your data. Your private moments stay completely yours.
    public static let subheadingText3 = L10n.tr("Localizable", "OnboardingCarousel.SubheadingText3", fallback: "Encamera never collects your data. Your private moments stay completely yours.")
  }
  public enum PaywallView {
    /// Encamera
    public static let appName = L10n.tr("Localizable", "PaywallView.AppName", fallback: "Encamera")
    /// Back to plans
    public static let backToPlans = L10n.tr("Localizable", "PaywallView.BackToPlans", fallback: "Back to plans")
    /// BEST VALUE
    public static let bestValue = L10n.tr("Localizable", "PaywallView.BestValue", fallback: "BEST VALUE")
    /// BIGGEST SAVING
    public static let biggestSaving = L10n.tr("Localizable", "PaywallView.BiggestSaving", fallback: "BIGGEST SAVING")
    /// Alex & Mihai
    public static let builtByNames = L10n.tr("Localizable", "PaywallView.BuiltByNames", fallback: "Alex & Mihai")
    /// Committed to your privacy.
    public static let builtByPeople = L10n.tr("Localizable", "PaywallView.BuiltByPeople", fallback: "Committed to your privacy.")
    /// Check benefits
    public static let checkBenefits = L10n.tr("Localizable", "PaywallView.CheckBenefits", fallback: "Check benefits")
    /// CURRENT PLAN
    public static let currentPlan = L10n.tr("Localizable", "PaywallView.CurrentPlan", fallback: "CURRENT PLAN")
    /// Everything you get
    /// with Premium
    public static let everythingYouGet = L10n.tr("Localizable", "PaywallView.EverythingYouGet", fallback: "Everything you get\nwith Premium")
    /// Get %@
    public static func getButton(_ p1: Any) -> String {
      return L10n.tr("Localizable", "PaywallView.GetButton", String(describing: p1), fallback: "Get %@")
    }
    /// One-time payment for unlimited storage plus updates for one year only
    public static let lifetimeLimitedDescription = L10n.tr("Localizable", "PaywallView.LifetimeLimitedDescription", fallback: "One-time payment for unlimited storage plus updates for one year only")
    /// Pay once, use forever
    public static let lifetimeLimitedSubtext = L10n.tr("Localizable", "PaywallView.LifetimeLimitedSubtext", fallback: "Pay once, use forever")
    /// Ultimate choice for users who demand complete protection that lasts forever
    public static let lifetimeUnlimitedDescription = L10n.tr("Localizable", "PaywallView.LifetimeUnlimitedDescription", fallback: "Ultimate choice for users who demand complete protection that lasts forever")
    /// Pay once, updates forever
    public static let lifetimeUnlimitedSubtext = L10n.tr("Localizable", "PaywallView.LifetimeUnlimitedSubtext", fallback: "Pay once, updates forever")
    /// MOST FLEXIBLE
    public static let mostFlexible = L10n.tr("Localizable", "PaywallView.MostFlexible", fallback: "MOST FLEXIBLE")
    /// ONE-TIME PAYMENT
    public static let oneTimePayment = L10n.tr("Localizable", "PaywallView.OneTimePayment", fallback: "ONE-TIME PAYMENT")
    /// Premium
    public static let premium = L10n.tr("Localizable", "PaywallView.Premium", fallback: "Premium")
    /// Privacy Policy
    public static let privacyPolicy = L10n.tr("Localizable", "PaywallView.PrivacyPolicy", fallback: "Privacy Policy")
    /// Restore Purchase
    public static let restorePurchase = L10n.tr("Localizable", "PaywallView.RestorePurchase", fallback: "Restore Purchase")
    /// Select the right plan for you
    public static let selectPlan = L10n.tr("Localizable", "PaywallView.SelectPlan", fallback: "Select the right plan for you")
    /// Terms of Service
    public static let termsOfService = L10n.tr("Localizable", "PaywallView.TermsOfService", fallback: "Terms of Service")
    /// Ideal for users seeking continuous protection with the best annual savings
    public static let unlimitedAnnualDescription = L10n.tr("Localizable", "PaywallView.UnlimitedAnnualDescription", fallback: "Ideal for users seeking continuous protection with the best annual savings")
    /// Billed yearly
    public static let unlimitedAnnualSubtext = L10n.tr("Localizable", "PaywallView.UnlimitedAnnualSubtext", fallback: "Billed yearly")
    /// %@ per month, billed yearly
    public static func unlimitedAnnualSubtextWithMonthlyPrice(_ p1: Any) -> String {
      return L10n.tr("Localizable", "PaywallView.UnlimitedAnnualSubtextWithMonthlyPrice", String(describing: p1), fallback: "%@ per month, billed yearly")
    }
    /// Great for users who value flexibility and month-to-month freedom
    public static let unlimitedMonthlyDescription = L10n.tr("Localizable", "PaywallView.UnlimitedMonthlyDescription", fallback: "Great for users who value flexibility and month-to-month freedom")
    /// Billed monthly, 7 day free trial
    public static let unlimitedMonthlySubtext = L10n.tr("Localizable", "PaywallView.UnlimitedMonthlySubtext", fallback: "Billed monthly, 7 day free trial")
    /// Unlimited Storage
    public static let unlimitedStorage = L10n.tr("Localizable", "PaywallView.UnlimitedStorage", fallback: "Unlimited Storage")
    /// UNLOCK
    public static let unlock = L10n.tr("Localizable", "PaywallView.Unlock", fallback: "UNLOCK")
    public enum AlbumPreview {
      /// 8 items
      public static let eightItems = L10n.tr("Localizable", "PaywallView.AlbumPreview.EightItems", fallback: "8 items")
      /// Our Trips
      public static let ourTrips = L10n.tr("Localizable", "PaywallView.AlbumPreview.OurTrips", fallback: "Our Trips")
      /// Private 🔒
      public static let privatePics = L10n.tr("Localizable", "PaywallView.AlbumPreview.PrivatePics", fallback: "Private 🔒")
      /// 16 items
      public static let sixteenItems = L10n.tr("Localizable", "PaywallView.AlbumPreview.SixteenItems", fallback: "16 items")
    }
    public enum Benefit {
      /// Change App Icon
      public static let changeAppIcon = L10n.tr("Localizable", "PaywallView.Benefit.ChangeAppIcon", fallback: "Change App Icon")
      /// Make Encamera looks like a normal app
      public static let changeAppIconDescription = L10n.tr("Localizable", "PaywallView.Benefit.ChangeAppIconDescription", fallback: "Make Encamera looks like a normal app")
      /// Hidden Albums
      public static let hiddenAlbums = L10n.tr("Localizable", "PaywallView.Benefit.HiddenAlbums", fallback: "Hidden Albums")
      /// Keep private memories out of sight
      public static let hiddenAlbumsDescription = L10n.tr("Localizable", "PaywallView.Benefit.HiddenAlbumsDescription", fallback: "Keep private memories out of sight")
      /// iCloud Keychain Backup
      public static let iCloudKeychainBackup = L10n.tr("Localizable", "PaywallView.Benefit.iCloudKeychainBackup", fallback: "iCloud Keychain Backup")
      /// Your encryption key stored on iCloud
      public static let iCloudKeychainBackupDescription = L10n.tr("Localizable", "PaywallView.Benefit.iCloudKeychainBackupDescription", fallback: "Your encryption key stored on iCloud")
      /// Unlimited Albums
      public static let unlimitedAlbums = L10n.tr("Localizable", "PaywallView.Benefit.UnlimitedAlbums", fallback: "Unlimited Albums")
      /// Organize memories without any limits
      public static let unlimitedAlbumsDescription = L10n.tr("Localizable", "PaywallView.Benefit.UnlimitedAlbumsDescription", fallback: "Organize memories without any limits")
      /// Unlimited Storage
      public static let unlimitedStorage = L10n.tr("Localizable", "PaywallView.Benefit.UnlimitedStorage", fallback: "Unlimited Storage")
      /// Keep every photo and video, forever
      public static let unlimitedStorageDescription = L10n.tr("Localizable", "PaywallView.Benefit.UnlimitedStorageDescription", fallback: "Keep every photo and video, forever")
    }
  }
  public enum PendingImport {
    /// This will cancel the import of this media. Do you want to continue?
    public static let cancelConfirmMessage = L10n.tr("Localizable", "PendingImport.CancelConfirmMessage", fallback: "This will cancel the import of this media. Do you want to continue?")
    /// Cancel Import?
    public static let cancelConfirmTitle = L10n.tr("Localizable", "PendingImport.CancelConfirmTitle", fallback: "Cancel Import?")
    /// Delete Media
    public static let deleteMedia = L10n.tr("Localizable", "PendingImport.DeleteMedia", fallback: "Delete Media")
    /// Select an album to move %d items
    public static func description(_ p1: Int) -> String {
      return L10n.tr("Localizable", "PendingImport.Description", p1, fallback: "Select an album to move %d items")
    }
    /// Import & Encrypt
    public static let importButton = L10n.tr("Localizable", "PendingImport.ImportButton", fallback: "Import & Encrypt")
    /// Select destination album:
    public static let selectAlbum = L10n.tr("Localizable", "PendingImport.SelectAlbum", fallback: "Select destination album:")
    /// ./Encamera/MediaImport/PendingImportView.swift - Pending Import
    public static let title = L10n.tr("Localizable", "PendingImport.Title", fallback: "Import Media")
  }
  public enum PhotoDeletion {
    /// Nothing was deleted from your photo library.
    public static let cancelledMessage = L10n.tr("Localizable", "PhotoDeletion.CancelledMessage", fallback: "Nothing was deleted from your photo library.")
    /// Couldn't delete from your photo library: %@
    public static func failedMessage(_ p1: Any) -> String {
      return L10n.tr("Localizable", "PhotoDeletion.FailedMessage", String(describing: p1), fallback: "Couldn't delete from your photo library: %@")
    }
    /// Those photos could not be found in your photo library. They may no longer be shared with Encamera.
    public static let notFoundMessage = L10n.tr("Localizable", "PhotoDeletion.NotFoundMessage", fallback: "Those photos could not be found in your photo library. They may no longer be shared with Encamera.")
    /// ./Encamera/Utils/PhotoDeletionManager.swift
    public static let outcomeTitle = L10n.tr("Localizable", "PhotoDeletion.OutcomeTitle", fallback: "Delete from Photos")
    /// Deleted %@ from your photo library. %@ could not be found — they may no longer be shared with Encamera.
    public static func partialMessage(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "PhotoDeletion.PartialMessage", String(describing: p1), String(describing: p2), fallback: "Deleted %@ from your photo library. %@ could not be found — they may no longer be shared with Encamera.")
    }
  }
  public enum PostPurchaseView {
    /// Maybe Later
    public static let maybeLater = L10n.tr("Localizable", "PostPurchaseView.MaybeLater", fallback: "Maybe Later")
    /// Help us with a review
    public static let reviewButton = L10n.tr("Localizable", "PostPurchaseView.ReviewButton", fallback: "Help us with a review")
    /// You are one of the early supporters of Encamera and we thank you for the support!
    public static let subtext1 = L10n.tr("Localizable", "PostPurchaseView.Subtext1", fallback: "You are one of the early supporters of Encamera and we thank you for the support!")
    /// In the meantime, we would highly appreciate if you could help us with a Review on the App Store
    public static let subtext2 = L10n.tr("Localizable", "PostPurchaseView.Subtext2", fallback: "In the meantime, we would highly appreciate if you could help us with a Review on the App Store")
    /// Thanks for your purchase!
    public static let thanksForYourPurchase = L10n.tr("Localizable", "PostPurchaseView.ThanksForYourPurchase", fallback: "Thanks for your purchase!")
  }
  public enum ProductPrice {
    /// ./Encamera/Store/ProductPrice.swift
    public static func salePercentageOff(_ p1: Int) -> String {
      return L10n.tr("Localizable", "ProductPrice.SalePercentageOff", p1, fallback: "%d%% OFF")
    }
  }
  public enum ProgressView {
    /// Decrypting: %.0f%%
    public static func decrypting(_ p1: Float) -> String {
      return L10n.tr("Localizable", "ProgressView.Decrypting", p1, fallback: "Decrypting: %.0f%%")
    }
    /// Downloading: %.0f%%
    public static func downloading(_ p1: Float) -> String {
      return L10n.tr("Localizable", "ProgressView.Downloading", p1, fallback: "Downloading: %.0f%%")
    }
    /// File loaded successfully
    public static let fileLoadedSuccessfully = L10n.tr("Localizable", "ProgressView.FileLoadedSuccessfully", fallback: "File loaded successfully")
    /// Starting download...
    public static let startingDownload = L10n.tr("Localizable", "ProgressView.StartingDownload", fallback: "Starting download...")
  }
  public enum PromotionalBanner {
    /// Dismiss banner
    public static let dismissAccessibility = L10n.tr("Localizable", "PromotionalBanner.DismissAccessibility", fallback: "Dismiss banner")
    /// ./Encamera/Components/PromotionalBannerView.swift
    public static let imageLoadError = L10n.tr("Localizable", "PromotionalBanner.ImageLoadError", fallback: "Image failed to load")
  }
  public enum ProtectionLevel {
    /// ./EncameraCore/Authentication/PasscodeType.swift
    public static let low = L10n.tr("Localizable", "ProtectionLevel.Low", fallback: "Low protection")
    /// Moderate protection
    public static let moderate = L10n.tr("Localizable", "ProtectionLevel.Moderate", fallback: "Moderate protection")
    /// Strong protection
    public static let strong = L10n.tr("Localizable", "ProtectionLevel.Strong", fallback: "Strong protection")
    /// Strongest protection
    public static let strongest = L10n.tr("Localizable", "ProtectionLevel.Strongest", fallback: "Strongest protection")
  }
  public enum PurchaseScreen {
    /// Unable to load subscriptions
    public static let errorLoadingSubscriptions = L10n.tr("Localizable", "PurchaseScreen.ErrorLoadingSubscriptions", fallback: "Unable to load subscriptions")
    /// Loading subscriptions...
    public static let loadingSubscriptions = L10n.tr("Localizable", "PurchaseScreen.LoadingSubscriptions", fallback: "Loading subscriptions...")
    /// Retry
    public static let retry = L10n.tr("Localizable", "PurchaseScreen.Retry", fallback: "Retry")
  }
  public enum PurchaseView {
    /// Unlock all of these benefits:
    public static let unlockBenefits = L10n.tr("Localizable", "PurchaseView.UnlockBenefits", fallback: "Unlock all of these benefits:")
    /// Your Premium benefits:
    public static let yourBenefits = L10n.tr("Localizable", "PurchaseView.YourBenefits", fallback: "Your Premium benefits:")
    public enum BenefitModel {
      /// Backup keychain to iCloud
      public static let backupKeychain = L10n.tr("Localizable", "PurchaseView.BenefitModel.BackupKeychain", fallback: "Backup keychain to iCloud")
      /// Change app icon
      public static let changeAppIcon = L10n.tr("Localizable", "PurchaseView.BenefitModel.ChangeAppIcon", fallback: "Change app icon")
      /// Coming Soon
      public static let comingSoon = L10n.tr("Localizable", "PurchaseView.BenefitModel.ComingSoon", fallback: "Coming Soon")
      /// Hidden albums
      public static let hiddenAlbums = L10n.tr("Localizable", "PurchaseView.BenefitModel.HiddenAlbums", fallback: "Hidden albums")
      /// iCloud storage & backup
      public static let iCloudStorage = L10n.tr("Localizable", "PurchaseView.BenefitModel.iCloudStorage", fallback: "iCloud storage & backup")
      /// Unlimited albums for your memories
      public static let unlimitedAlbums = L10n.tr("Localizable", "PurchaseView.BenefitModel.UnlimitedAlbums", fallback: "Unlimited albums for your memories")
      /// Unlimited storage for photos & videos
      public static let unlimitedStorage = L10n.tr("Localizable", "PurchaseView.BenefitModel.UnlimitedStorage", fallback: "Unlimited storage for photos & videos")
    }
  }
  public enum RestoringFromICloud {
    /// Enter key phrase instead
    public static let enterKeyPhrase = L10n.tr("Localizable", "RestoringFromICloud.EnterKeyPhrase", fallback: "Enter key phrase instead")
    /// Finishing restore…
    public static let finishingRestore = L10n.tr("Localizable", "RestoringFromICloud.FinishingRestore", fallback: "Finishing restore…")
    /// Set up as a new device
    public static let setUpAsNew = L10n.tr("Localizable", "RestoringFromICloud.SetUpAsNew", fallback: "Set up as a new device")
    /// Looking for your Encamera account from another device. This usually takes a few seconds.
    public static let subtitle = L10n.tr("Localizable", "RestoringFromICloud.Subtitle", fallback: "Looking for your Encamera account from another device. This usually takes a few seconds.")
    /// ./Encamera/Components/RestoringFromiCloudView.swift - iCloud Keychain restore wait screen
    public static let title = L10n.tr("Localizable", "RestoringFromICloud.Title", fallback: "Restoring from iCloud…")
  }
  public enum ReturningUser {
    /// We found an existing Encamera account linked to your iCloud. Choose how you'd like to continue on this device.
    public static let body = L10n.tr("Localizable", "ReturningUser.Body", fallback: "We found an existing Encamera account linked to your iCloud. Choose how you'd like to continue on this device.")
    /// The delete-my-data flow isn't built yet. This is a placeholder for the upcoming destructive path.
    public static let deleteBody = L10n.tr("Localizable", "ReturningUser.DeleteBody", fallback: "The delete-my-data flow isn't built yet. This is a placeholder for the upcoming destructive path.")
    /// Delete existing data
    public static let deleteTitle = L10n.tr("Localizable", "ReturningUser.DeleteTitle", fallback: "Delete existing data")
    /// I don't have my key
    public static let iDontHaveMyKey = L10n.tr("Localizable", "ReturningUser.IDontHaveMyKey", fallback: "I don't have my key")
    /// I have my key
    public static let iHaveMyKey = L10n.tr("Localizable", "ReturningUser.IHaveMyKey", fallback: "I have my key")
    /// It's on my other device
    public static let keyOnOtherDevice = L10n.tr("Localizable", "ReturningUser.KeyOnOtherDevice", fallback: "It's on my other device")
    /// Previously used on: %@
    public static func knownDevices(_ p1: Any) -> String {
      return L10n.tr("Localizable", "ReturningUser.KnownDevices", String(describing: p1), fallback: "Previously used on: %@")
    }
    /// %d encrypted items found in iCloud
    public static func mediaCountCloud(_ p1: Int) -> String {
      return L10n.tr("Localizable", "ReturningUser.MediaCountCloud", p1, fallback: "%d encrypted items found in iCloud")
    }
    /// %d files found in iCloud Drive
    public static func mediaCountLegacy(_ p1: Int) -> String {
      return L10n.tr("Localizable", "ReturningUser.MediaCountLegacy", p1, fallback: "%d files found in iCloud Drive")
    }
    /// Continue
    public static let placeholderContinue = L10n.tr("Localizable", "ReturningUser.PlaceholderContinue", fallback: "Continue")
    /// Key recovery isn't built yet. This is a placeholder for the upcoming recovery flow.
    public static let recoveryBody = L10n.tr("Localizable", "ReturningUser.RecoveryBody", fallback: "Key recovery isn't built yet. This is a placeholder for the upcoming recovery flow.")
    /// Recover your key
    public static let recoveryTitle = L10n.tr("Localizable", "ReturningUser.RecoveryTitle", fallback: "Recover your key")
    /// Set up as a new device
    public static let setUpAsNew = L10n.tr("Localizable", "ReturningUser.SetUpAsNew", fallback: "Set up as a new device")
    /// ./Encamera/Onboarding/OnboardingHostingView.swift - Returning-user branch screen (ENC-91). Placeholder copy pending design (ENC-75).
    public static let title = L10n.tr("Localizable", "ReturningUser.Title", fallback: "You've used Encamera before")
    public enum Destructive {
      /// Continue
      public static let `continue` = L10n.tr("Localizable", "ReturningUser.Destructive.Continue", fallback: "Continue")
      /// Deleting your iCloud data…
      public static let deleting = L10n.tr("Localizable", "ReturningUser.Destructive.Deleting", fallback: "Deleting your iCloud data…")
      /// You're about to remove the Encamera data stored in your iCloud. Review what will be deleted before you continue.
      public static let existsBody = L10n.tr("Localizable", "ReturningUser.Destructive.ExistsBody", fallback: "You're about to remove the Encamera data stored in your iCloud. Review what will be deleted before you continue.")
      /// ./Encamera/Onboarding/OnboardingHostingView.swift - Destructive delete-my-iCloud-data path (ENC-94). Escalating confirmation, then hold-to-delete. Placeholder copy pending design (ENC-101/102).
      public static let existsTitle = L10n.tr("Localizable", "ReturningUser.Destructive.ExistsTitle", fallback: "Delete your iCloud data")
      /// Something went wrong and the deletion did not finish. Your iCloud data has not been fully deleted. Please try again.
      public static let failedBody = L10n.tr("Localizable", "ReturningUser.Destructive.FailedBody", fallback: "Something went wrong and the deletion did not finish. Your iCloud data has not been fully deleted. Please try again.")
      /// This data was created on another device.
      public static let genericScope = L10n.tr("Localizable", "ReturningUser.Destructive.GenericScope", fallback: "This data was created on another device.")
      /// Hold the button to permanently delete your iCloud data. This is your last chance to cancel.
      public static let holdBody = L10n.tr("Localizable", "ReturningUser.Destructive.HoldBody", fallback: "Hold the button to permanently delete your iCloud data. This is your last chance to cancel.")
      /// Hold to Delete
      public static let holdButton = L10n.tr("Localizable", "ReturningUser.Destructive.HoldButton", fallback: "Hold to Delete")
      /// Deleting in %d
      public static func holdCountdown(_ p1: Int) -> String {
        return L10n.tr("Localizable", "ReturningUser.Destructive.HoldCountdown", p1, fallback: "Deleting in %d")
      }
      /// Delete everything
      public static let holdTitle = L10n.tr("Localizable", "ReturningUser.Destructive.HoldTitle", fallback: "Delete everything")
      /// You must be online to delete your iCloud data. Connect to the internet and try again.
      public static let offline = L10n.tr("Localizable", "ReturningUser.Destructive.Offline", fallback: "You must be online to delete your iCloud data. Connect to the internet and try again.")
      /// Some of your data could not be deleted and still remains in iCloud. No new key was created. Please try again to finish deleting.
      public static let partialFailureBody = L10n.tr("Localizable", "ReturningUser.Destructive.PartialFailureBody", fallback: "Some of your data could not be deleted and still remains in iCloud. No new key was created. Please try again to finish deleting.")
      /// Deletion incomplete
      public static let partialFailureTitle = L10n.tr("Localizable", "ReturningUser.Destructive.PartialFailureTitle", fallback: "Deletion incomplete")
      /// There is no recovery and no support path — like a crypto wallet, once this data is gone it is gone forever. Only continue if you are certain you cannot recover your key.
      public static let warningBody = L10n.tr("Localizable", "ReturningUser.Destructive.WarningBody", fallback: "There is no recovery and no support path — like a crypto wallet, once this data is gone it is gone forever. Only continue if you are certain you cannot recover your key.")
      /// This cannot be undone
      public static let warningTitle = L10n.tr("Localizable", "ReturningUser.Destructive.WarningTitle", fallback: "This cannot be undone")
    }
  }
  public enum Settings {
    /// Couldn't Change Key Backup
    public static let backupKeyChangeFailed = L10n.tr("Localizable", "Settings.BackupKeyChangeFailed", fallback: "Couldn't Change Key Backup")
    /// Your iCloud Keychain refused the change, so this setting was left as it was. Make sure you're signed in to iCloud with Keychain turned on, then try again.
    public static let backupKeyChangeFailedMessage = L10n.tr("Localizable", "Settings.BackupKeyChangeFailedMessage", fallback: "Your iCloud Keychain refused the change, so this setting was left as it was. Make sure you're signed in to iCloud with Keychain turned on, then try again.")
    /// Backup Key Phrase
    public static let backupKeyPhrase = L10n.tr("Localizable", "Settings.BackupKeyPhrase", fallback: "Backup Key Phrase")
    /// Sync Key to iCloud
    public static let backupKeyToiCloud = L10n.tr("Localizable", "Settings.BackupKeyToiCloud", fallback: "Sync Key to iCloud")
    /// If enabled, your key will automatically be backed up to your iCloud Keychain. If you lose your device, you will still have access to files stored on iCloud if you choose this option.
    public static let backupKeyToiCloudDescription = L10n.tr("Localizable", "Settings.BackupKeyToiCloudDescription", fallback: "If enabled, your key will automatically be backed up to your iCloud Keychain. If you lose your device, you will still have access to files stored on iCloud if you choose this option.")
    /// Banners Cleared
    public static let bannersCleared = L10n.tr("Localizable", "Settings.BannersCleared", fallback: "Banners Cleared")
    /// All dismissed banners have been reset and will appear again.
    public static let bannersClearedMessage = L10n.tr("Localizable", "Settings.BannersClearedMessage", fallback: "All dismissed banners have been reset and will appear again.")
    /// Reset Banners
    public static let clearDismissedBanners = L10n.tr("Localizable", "Settings.ClearDismissedBanners", fallback: "Reset Banners")
    /// Contact Support
    public static let contact = L10n.tr("Localizable", "Settings.Contact", fallback: "Contact Support")
    /// Copied to clipboard
    public static let copiedToClipboard = L10n.tr("Localizable", "Settings.CopiedToClipboard", fallback: "Copied to clipboard")
    /// Default Storage Option
    public static let defaultStorageOption = L10n.tr("Localizable", "Settings.DefaultStorageOption", fallback: "Default Storage Option")
    /// Erasing finished, but some of your data is still on this device, so the app has not been reset. Please try again, and contact support if it keeps happening.
    /// 
    /// Still present:
    /// %@
    public static func eraseIncompleteMessage(_ p1: Any) -> String {
      return L10n.tr("Localizable", "Settings.EraseIncompleteMessage", String(describing: p1), fallback: "Erasing finished, but some of your data is still on this device, so the app has not been reset. Please try again, and contact support if it keeps happening.\n\nStill present:\n%@")
    }
    /// Some data could not be erased
    public static let eraseIncompleteTitle = L10n.tr("Localizable", "Settings.EraseIncompleteTitle", fallback: "Some data could not be erased")
    /// Give Instant Feedback
    public static let giveInstantFeedback = L10n.tr("Localizable", "Settings.GiveInstantFeedback", fallback: "Give Instant Feedback")
    /// Hidden Albums
    public static let hiddenAlbums = L10n.tr("Localizable", "Settings.HiddenAlbums", fallback: "Hidden Albums")
    /// Your data on this device was erased, but we couldn't remove your data from iCloud. Reconnect to the internet (and make sure you're signed in to iCloud), then run Erase All Data again.
    public static let icloudDataMayRemainMessage = L10n.tr("Localizable", "Settings.IcloudDataMayRemainMessage", fallback: "Your data on this device was erased, but we couldn't remove your data from iCloud. Reconnect to the internet (and make sure you're signed in to iCloud), then run Erase All Data again.")
    /// iCloud data may not be deleted
    public static let icloudDataMayRemainTitle = L10n.tr("Localizable", "Settings.IcloudDataMayRemainTitle", fallback: "iCloud data may not be deleted")
    /// Import Key Phrase
    public static let importKeyPhrase = L10n.tr("Localizable", "Settings.ImportKeyPhrase", fallback: "Import Key Phrase")
    /// Loop Videos
    public static let loopVideos = L10n.tr("Localizable", "Settings.LoopVideos", fallback: "Loop Videos")
    /// iCloud Multi-Device Mode
    public static let multiDeviceMode = L10n.tr("Localizable", "Settings.MultiDeviceMode", fallback: "iCloud Multi-Device Mode")
    /// Your key and passcode sync through iCloud Keychain, so Encamera works seamlessly on your other devices. Turning this off removes them from your other devices.
    public static let multiDeviceModeDescription = L10n.tr("Localizable", "Settings.MultiDeviceModeDescription", fallback: "Your key and passcode sync through iCloud Keychain, so Encamera works seamlessly on your other devices. Turning this off removes them from your other devices.")
    /// Purchases restored!
    public static let purchasesRestored = L10n.tr("Localizable", "Settings.PurchasesRestored", fallback: "Purchases restored!")
    /// Any valid purchases you made have been restored.
    public static let purchasesRestoredMessage = L10n.tr("Localizable", "Settings.PurchasesRestoredMessage", fallback: "Any valid purchases you made have been restored.")
    /// Could not restore purchases
    public static let purchasesRestoreFailed = L10n.tr("Localizable", "Settings.PurchasesRestoreFailed", fallback: "Could not restore purchases")
    /// Could not restore your purchases. Please try again or contact support.
    public static let purchasesRestoreFailedMessage = L10n.tr("Localizable", "Settings.PurchasesRestoreFailedMessage", fallback: "Could not restore your purchases. Please try again or contact support.")
    /// RevenueCat Customer ID
    public static let revenueCatCustomerId = L10n.tr("Localizable", "Settings.RevenueCatCustomerId", fallback: "RevenueCat Customer ID")
    /// Hidden Albums in Camera
    public static let showHiddenAlbumsInCameraPicker = L10n.tr("Localizable", "Settings.ShowHiddenAlbumsInCameraPicker", fallback: "Hidden Albums in Camera")
    /// Version
    public static let version = L10n.tr("Localizable", "Settings.Version", fallback: "Version")
    public enum HiddenAlbumsModal {
      /// %@ ALBUMS
      public static func albumsCount(_ p1: Any) -> String {
        return L10n.tr("Localizable", "Settings.HiddenAlbumsModal.AlbumsCount", String(describing: p1), fallback: "%@ ALBUMS")
      }
      /// Access them by creating a new album with the exact same name
      public static let subtitle = L10n.tr("Localizable", "Settings.HiddenAlbumsModal.Subtitle", fallback: "Access them by creating a new album with the exact same name")
      /// Your hidden albums
      public static let title = L10n.tr("Localizable", "Settings.HiddenAlbumsModal.Title", fallback: "Your hidden albums")
    }
    public enum MultiDeviceMode {
      /// Turning off Multi-Device Mode removes your key and passcode from your iCloud Keychain. This device keeps its copy. Any other device that only had the iCloud copy — including %@ — will no longer be able to open your photos.
      public static func disableDevicesWarning(_ p1: Any) -> String {
        return L10n.tr("Localizable", "Settings.MultiDeviceMode.DisableDevicesWarning", String(describing: p1), fallback: "Turning off Multi-Device Mode removes your key and passcode from your iCloud Keychain. This device keeps its copy. Any other device that only had the iCloud copy — including %@ — will no longer be able to open your photos.")
      }
      /// Turning off Multi-Device Mode removes your key and passcode from your iCloud Keychain. This device keeps its copy. Any other device that only had the iCloud copy will no longer be able to open your photos.
      public static let disableGenericWarning = L10n.tr("Localizable", "Settings.MultiDeviceMode.DisableGenericWarning", fallback: "Turning off Multi-Device Mode removes your key and passcode from your iCloud Keychain. This device keeps its copy. Any other device that only had the iCloud copy will no longer be able to open your photos.")
      /// Turn off iCloud Multi-Device Mode?
      public static let disableTitle = L10n.tr("Localizable", "Settings.MultiDeviceMode.DisableTitle", fallback: "Turn off iCloud Multi-Device Mode?")
      /// Turning off in %d
      public static func disablingIn(_ p1: Int) -> String {
        return L10n.tr("Localizable", "Settings.MultiDeviceMode.DisablingIn", p1, fallback: "Turning off in %d")
      }
      /// Your iCloud Keychain already holds a different key. This device uses key %1$@, and your iCloud account already has key %2$@. Encamera keeps both keys — neither one is deleted or overwritten — and %1$@ stays the key this device uses for new photos. The other key stays available so its photos can still be opened.
      public static func enableConflictWarning(_ p1: Any, _ p2: Any) -> String {
        return L10n.tr("Localizable", "Settings.MultiDeviceMode.EnableConflictWarning", String(describing: p1), String(describing: p2), fallback: "Your iCloud Keychain already holds a different key. This device uses key %1$@, and your iCloud account already has key %2$@. Encamera keeps both keys — neither one is deleted or overwritten — and %1$@ stays the key this device uses for new photos. The other key stays available so its photos can still be opened.")
      }
      /// Your iCloud Keychain already holds other keys. This device uses key %1$@, and your iCloud account already has these keys: %2$@. Encamera keeps every one of them — none is deleted or overwritten — and %1$@ stays the key this device uses for new photos. The other keys stay available so their photos can still be opened.
      public static func enableConflictWarningMultiple(_ p1: Any, _ p2: Any) -> String {
        return L10n.tr("Localizable", "Settings.MultiDeviceMode.EnableConflictWarningMultiple", String(describing: p1), String(describing: p2), fallback: "Your iCloud Keychain already holds other keys. This device uses key %1$@, and your iCloud account already has these keys: %2$@. Encamera keeps every one of them — none is deleted or overwritten — and %1$@ stays the key this device uses for new photos. The other keys stay available so their photos can still be opened.")
      }
      /// Your key and passcode will be copied into your iCloud Keychain so your other Apple devices can open your albums. Anyone who can unlock your iCloud account can then reach them.
      public static let enableSimpleWarning = L10n.tr("Localizable", "Settings.MultiDeviceMode.EnableSimpleWarning", fallback: "Your key and passcode will be copied into your iCloud Keychain so your other Apple devices can open your albums. Anyone who can unlock your iCloud account can then reach them.")
      /// Turn on iCloud Multi-Device Mode?
      public static let enableTitle = L10n.tr("Localizable", "Settings.MultiDeviceMode.EnableTitle", fallback: "Turn on iCloud Multi-Device Mode?")
      /// Turning on in %d
      public static func enablingIn(_ p1: Int) -> String {
        return L10n.tr("Localizable", "Settings.MultiDeviceMode.EnablingIn", p1, fallback: "Turning on in %d")
      }
      /// Multi-Device Mode could not be changed. Your key and passcode were left as they were, and the switch has been set back to the real setting.
      public static let flipFailed = L10n.tr("Localizable", "Settings.MultiDeviceMode.FlipFailed", fallback: "Multi-Device Mode could not be changed. Your key and passcode were left as they were, and the switch has been set back to the real setting.")
      /// Hold to Turn Off
      public static let holdToDisable = L10n.tr("Localizable", "Settings.MultiDeviceMode.HoldToDisable", fallback: "Hold to Turn Off")
      /// Hold to Turn On
      public static let holdToEnable = L10n.tr("Localizable", "Settings.MultiDeviceMode.HoldToEnable", fallback: "Hold to Turn On")
      /// Move to iCloud
      public static let migrateAlbumsConfirm = L10n.tr("Localizable", "Settings.MultiDeviceMode.MigrateAlbumsConfirm", fallback: "Move to iCloud")
      /// These albums are still stored only on this device: %@. Your photos are safe — open an album to try moving it again.
      public static func migrateAlbumsFailedMessage(_ p1: Any) -> String {
        return L10n.tr("Localizable", "Settings.MultiDeviceMode.MigrateAlbumsFailedMessage", String(describing: p1), fallback: "These albums are still stored only on this device: %@. Your photos are safe — open an album to try moving it again.")
      }
      /// Some albums didn't move
      public static let migrateAlbumsFailedTitle = L10n.tr("Localizable", "Settings.MultiDeviceMode.MigrateAlbumsFailedTitle", fallback: "Some albums didn't move")
      /// %d of your albums are stored only on this device. Moving them to iCloud lets your other devices see them. You can leave them here and move them later instead.
      public static func migrateAlbumsMessage(_ p1: Int) -> String {
        return L10n.tr("Localizable", "Settings.MultiDeviceMode.MigrateAlbumsMessage", p1, fallback: "%d of your albums are stored only on this device. Moving them to iCloud lets your other devices see them. You can leave them here and move them later instead.")
      }
      /// Keep on This Device
      public static let migrateAlbumsSkip = L10n.tr("Localizable", "Settings.MultiDeviceMode.MigrateAlbumsSkip", fallback: "Keep on This Device")
      /// Move your albums to iCloud?
      public static let migrateAlbumsTitle = L10n.tr("Localizable", "Settings.MultiDeviceMode.MigrateAlbumsTitle", fallback: "Move your albums to iCloud?")
    }
  }
  public enum SettingsView {
    /// ./Encamera/Settings/SettingsView.swift
    public static let unknownError = L10n.tr("Localizable", "SettingsView.UnknownError", fallback: "Unknown error")
    public enum SectionHeader {
      /// APP SETTINGS
      public static let appSettings = L10n.tr("Localizable", "SettingsView.SectionHeader.AppSettings", fallback: "APP SETTINGS")
      /// GENERAL
      public static let general = L10n.tr("Localizable", "SettingsView.SectionHeader.General", fallback: "GENERAL")
      /// GET HELP
      public static let getHelp = L10n.tr("Localizable", "SettingsView.SectionHeader.GetHelp", fallback: "GET HELP")
      /// PREMIUM
      public static let premiumPlan = L10n.tr("Localizable", "SettingsView.SectionHeader.PremiumPlan", fallback: "PREMIUM")
    }
  }
  public enum ShareExtension {
    /// %d item(s) saved
    public static func mediaSaved(_ p1: Int) -> String {
      return L10n.tr("Localizable", "ShareExtension.MediaSaved", p1, fallback: "%d item(s) saved")
    }
    /// Open Encamera to finish importing your media and encrypting it.
    public static let openAppToComplete = L10n.tr("Localizable", "ShareExtension.OpenAppToComplete", fallback: "Open Encamera to finish importing your media and encrypting it.")
    /// Open Encamera
    public static let openEncamera = L10n.tr("Localizable", "ShareExtension.OpenEncamera", fallback: "Open Encamera")
    /// Failed to save media
    public static let saveFailed = L10n.tr("Localizable", "ShareExtension.SaveFailed", fallback: "Failed to save media")
    /// ./ShareExtension/ShareViewController.swift - Share Extension
    public static let savingMedia = L10n.tr("Localizable", "ShareExtension.SavingMedia", fallback: "Saving media...")
  }
  public enum SplashScreen {
    /// Secure Your Memories
    public static let subline = L10n.tr("Localizable", "SplashScreen.Subline", fallback: "Secure Your Memories")
  }
  public enum StorageInsights {
    /// Downloaded from iCloud
    public static let cachedCloud = L10n.tr("Localizable", "StorageInsights.CachedCloud", fallback: "Downloaded from iCloud")
    /// %@ can be freed
    public static func canBeFreed(_ p1: Any) -> String {
      return L10n.tr("Localizable", "StorageInsights.CanBeFreed", String(describing: p1), fallback: "%@ can be freed")
    }
    /// Photos you take or import will show up here.
    public static let emptySubtitle = L10n.tr("Localizable", "StorageInsights.EmptySubtitle", fallback: "Photos you take or import will show up here.")
    /// Nothing stored on this device yet
    public static let emptyTitle = L10n.tr("Localizable", "StorageInsights.EmptyTitle", fallback: "Nothing stored on this device yet")
    /// Couldn't measure storage
    public static let errorTitle = L10n.tr("Localizable", "StorageInsights.ErrorTitle", fallback: "Couldn't measure storage")
    /// Show a Settings screen breaking down how much space Encamera's media takes on this device and in iCloud, with an action that frees the re-downloadable cache
    public static let featureDescription = L10n.tr("Localizable", "StorageInsights.FeatureDescription", fallback: "Show a Settings screen breaking down how much space Encamera's media takes on this device and in iCloud, with an action that frees the re-downloadable cache")
    /// Storage Insights
    public static let featureTitle = L10n.tr("Localizable", "StorageInsights.FeatureTitle", fallback: "Storage Insights")
    /// %@ is now available. Your photos and videos are untouched.
    public static func freedMessage(_ p1: Any) -> String {
      return L10n.tr("Localizable", "StorageInsights.FreedMessage", String(describing: p1), fallback: "%@ is now available. Your photos and videos are untouched.")
    }
    /// Space freed
    public static let freedTitle = L10n.tr("Localizable", "StorageInsights.FreedTitle", fallback: "Space freed")
    /// Freeing up space…
    public static let freeing = L10n.tr("Localizable", "StorageInsights.Freeing", fallback: "Freeing up space…")
    /// ./Encamera/Settings/StorageInsightsView.swift - Free up space action
    public static let freeUpSpace = L10n.tr("Localizable", "StorageInsights.FreeUpSpace", fallback: "Free up space")
    /// Free up space
    public static let freeUpSpaceConfirm = L10n.tr("Localizable", "StorageInsights.FreeUpSpaceConfirm", fallback: "Free up space")
    /// Some cached files could not be removed. Nothing was deleted from your photos or videos.
    public static let freeUpSpaceFailedMessage = L10n.tr("Localizable", "StorageInsights.FreeUpSpaceFailedMessage", fallback: "Some cached files could not be removed. Nothing was deleted from your photos or videos.")
    /// Couldn't free up space
    public static let freeUpSpaceFailedTitle = L10n.tr("Localizable", "StorageInsights.FreeUpSpaceFailedTitle", fallback: "Couldn't free up space")
    /// This removes downloaded copies of media that is also stored in iCloud, along with previews and album indexes. None of your photos or videos are deleted — anything you open next will download again from iCloud.
    public static let freeUpSpaceMessage = L10n.tr("Localizable", "StorageInsights.FreeUpSpaceMessage", fallback: "This removes downloaded copies of media that is also stored in iCloud, along with previews and album indexes. None of your photos or videos are deleted — anything you open next will download again from iCloud.")
    /// Free up %@?
    public static func freeUpSpaceTitle(_ p1: Any) -> String {
      return L10n.tr("Localizable", "StorageInsights.FreeUpSpaceTitle", String(describing: p1), fallback: "Free up %@?")
    }
    /// Unavailable
    public static let iCloudUnavailable = L10n.tr("Localizable", "StorageInsights.ICloudUnavailable", fallback: "Unavailable")
    /// Sign in to iCloud to see how much is stored there.
    public static let iCloudUnavailableCaption = L10n.tr("Localizable", "StorageInsights.ICloudUnavailableCaption", fallback: "Sign in to iCloud to see how much is stored there.")
    /// Album indexes
    public static let indexes = L10n.tr("Localizable", "StorageInsights.Indexes", fallback: "Album indexes")
    /// In iCloud
    public static let inICloud = L10n.tr("Localizable", "StorageInsights.InICloud", fallback: "In iCloud")
    /// %d legacy iCloud Drive album(s) are managed by iOS and aren't included here.
    public static func legacyFootnote(_ p1: Int) -> String {
      return L10n.tr("Localizable", "StorageInsights.LegacyFootnote", p1, fallback: "%d legacy iCloud Drive album(s) are managed by iOS and aren't included here.")
    }
    /// Photos & videos on this device
    public static let localMedia = L10n.tr("Localizable", "StorageInsights.LocalMedia", fallback: "Photos & videos on this device")
    /// Measuring…
    public static let measuring = L10n.tr("Localizable", "StorageInsights.Measuring", fallback: "Measuring…")
    /// Nothing to free up
    public static let nothingToFree = L10n.tr("Localizable", "StorageInsights.NothingToFree", fallback: "Nothing to free up")
    /// On this device
    public static let onThisDevice = L10n.tr("Localizable", "StorageInsights.OnThisDevice", fallback: "On this device")
    /// Can be freed
    public static let reclaimable = L10n.tr("Localizable", "StorageInsights.Reclaimable", fallback: "Can be freed")
    /// Try again
    public static let retry = L10n.tr("Localizable", "StorageInsights.Retry", fallback: "Try again")
    /// Storage
    public static let settingsRow = L10n.tr("Localizable", "StorageInsights.SettingsRow", fallback: "Storage")
    /// Previews
    public static let thumbnails = L10n.tr("Localizable", "StorageInsights.Thumbnails", fallback: "Previews")
    /// ./Encamera/Settings/StorageInsightsView.swift - Storage Insights screen
    public static let title = L10n.tr("Localizable", "StorageInsights.Title", fallback: "Storage")
  }
  public enum StorageOption {
    /// %@ Storage
    public static func storage(_ p1: Any) -> String {
      return L10n.tr("Localizable", "StorageOption.Storage", String(describing: p1), fallback: "%@ Storage")
    }
  }
  public enum StorageType {
    /// iCloud Drive
    public static let iCloudDriveLegacyLocationName = L10n.tr("Localizable", "StorageType.ICloudDriveLegacyLocationName", fallback: "iCloud Drive")
    /// iCloud Drive (Legacy)
    public static let iCloudDriveLegacyTitle = L10n.tr("Localizable", "StorageType.ICloudDriveLegacyTitle", fallback: "iCloud Drive (Legacy)")
    /// Save to iCloud
    public static let saveToICloud = L10n.tr("Localizable", "StorageType.SaveToICloud", fallback: "Save to iCloud")
  }
  public enum SyncStatusBar {
    /// Checking iCloud for changes…
    public static let checking = L10n.tr("Localizable", "SyncStatusBar.Checking", fallback: "Checking iCloud for changes…")
    /// %d items could not be uploaded
    public static func stalled(_ p1: Int) -> String {
      return L10n.tr("Localizable", "SyncStatusBar.Stalled", p1, fallback: "%d items could not be uploaded")
    }
    /// ./Encamera/Components/SyncStatusBar.swift
    public static let title = L10n.tr("Localizable", "SyncStatusBar.Title", fallback: "iCloud sync")
    /// Uploading %d of %d to iCloud
    public static func uploading(_ p1: Int, _ p2: Int) -> String {
      return L10n.tr("Localizable", "SyncStatusBar.Uploading", p1, p2, fallback: "Uploading %d of %d to iCloud")
    }
    /// iCloud is up to date
    public static let upToDate = L10n.tr("Localizable", "SyncStatusBar.UpToDate", fallback: "iCloud is up to date")
  }
  public enum TaskDetailCard {
    /// Created: %@
    public static func created(_ p1: Any) -> String {
      return L10n.tr("Localizable", "TaskDetailCard.Created", String(describing: p1), fallback: "Created: %@")
    }
    /// Current: %@
    public static func current(_ p1: Any) -> String {
      return L10n.tr("Localizable", "TaskDetailCard.Current", String(describing: p1), fallback: "Current: %@")
    }
    /// Delete From Camera Roll
    public static let deleteFromCameraRoll = L10n.tr("Localizable", "TaskDetailCard.DeleteFromCameraRoll", fallback: "Delete From Camera Roll")
    /// This will delete %@ photo(s) from your Photo Library that were imported into Encamera.
    public static func deleteMessage(_ p1: Any) -> String {
      return L10n.tr("Localizable", "TaskDetailCard.DeleteMessage", String(describing: p1), fallback: "This will delete %@ photo(s) from your Photo Library that were imported into Encamera.")
    }
    /// Estimated time remaining: %@
    public static func estimatedTime(_ p1: Any) -> String {
      return L10n.tr("Localizable", "TaskDetailCard.EstimatedTime", String(describing: p1), fallback: "Estimated time remaining: %@")
    }
    /// Please grant access to your photo library in Settings to delete imported photos.
    public static let grantAccessMessage = L10n.tr("Localizable", "TaskDetailCard.GrantAccessMessage", fallback: "Please grant access to your photo library in Settings to delete imported photos.")
    /// Limited Photo Access
    public static let limitedAccessInfo = L10n.tr("Localizable", "TaskDetailCard.LimitedAccessInfo", fallback: "Limited Photo Access")
    /// With limited photo access, only photos you've selected can be deleted. To delete all imported photos, please grant full photo library access in Settings.
    public static let limitedAccessMessage = L10n.tr("Localizable", "TaskDetailCard.LimitedAccessMessage", fallback: "With limited photo access, only photos you've selected can be deleted. To delete all imported photos, please grant full photo library access in Settings.")
    /// Pause
    public static let pause = L10n.tr("Localizable", "TaskDetailCard.Pause", fallback: "Pause")
    /// Photo Library Access Required
    public static let photoLibraryAccessRequired = L10n.tr("Localizable", "TaskDetailCard.PhotoLibraryAccessRequired", fallback: "Photo Library Access Required")
    /// Progress:
    public static let progress = L10n.tr("Localizable", "TaskDetailCard.Progress", fallback: "Progress:")
    /// Resume
    public static let resume = L10n.tr("Localizable", "TaskDetailCard.Resume", fallback: "Resume")
    /// Cancelled
    public static let statusCancelled = L10n.tr("Localizable", "TaskDetailCard.StatusCancelled", fallback: "Cancelled")
    /// Completed
    public static let statusCompleted = L10n.tr("Localizable", "TaskDetailCard.StatusCompleted", fallback: "Completed")
    /// Failed
    public static let statusFailed = L10n.tr("Localizable", "TaskDetailCard.StatusFailed", fallback: "Failed")
    /// Paused
    public static let statusPaused = L10n.tr("Localizable", "TaskDetailCard.StatusPaused", fallback: "Paused")
    /// Preparing %d of %d files...
    public static func statusPreparing(_ p1: Int, _ p2: Int) -> String {
      return L10n.tr("Localizable", "TaskDetailCard.StatusPreparing", p1, p2, fallback: "Preparing %d of %d files...")
    }
    /// Running
    public static let statusRunning = L10n.tr("Localizable", "TaskDetailCard.StatusRunning", fallback: "Running")
    /// Waiting
    public static let statusWaiting = L10n.tr("Localizable", "TaskDetailCard.StatusWaiting", fallback: "Waiting")
    /// ./Encamera/Components/ImportProgress/TaskDetailCard.swift
    public static func taskID(_ p1: Any) -> String {
      return L10n.tr("Localizable", "TaskDetailCard.TaskID", String(describing: p1), fallback: "Task ID: %@")
    }
    /// Unknown
    public static let unknown = L10n.tr("Localizable", "TaskDetailCard.Unknown", fallback: "Unknown")
  }
  public enum TaskProgressRow {
    /// ./Encamera/Components/ImportProgress/TaskProgressRow.swift
    public static func processing(_ p1: Any) -> String {
      return L10n.tr("Localizable", "TaskProgressRow.Processing", String(describing: p1), fallback: "Processing: %@")
    }
  }
  public enum WelcomeBack {
    /// Enter passcode
    public static let `continue` = L10n.tr("Localizable", "WelcomeBack.Continue", fallback: "Enter passcode")
    /// We found your Encamera account from another device. Enter your passcode to unlock it here.
    public static let message = L10n.tr("Localizable", "WelcomeBack.Message", fallback: "We found your Encamera account from another device. Enter your passcode to unlock it here.")
    /// ./Encamera/Onboarding/OnboardingHostingView.swift - Welcome back takeover for synced accounts
    public static let title = L10n.tr("Localizable", "WelcomeBack.Title", fallback: "Welcome back!")
  }
  public enum ZipExport {
    /// Cancel
    public static let cancel = L10n.tr("Localizable", "ZipExport.Cancel", fallback: "Cancel")
    /// Close
    public static let close = L10n.tr("Localizable", "ZipExport.Close", fallback: "Close")
    /// Zip file ready!
    public static let complete = L10n.tr("Localizable", "ZipExport.Complete", fallback: "Zip file ready!")
    /// Compressing files...
    public static let compressing = L10n.tr("Localizable", "ZipExport.Compressing", fallback: "Compressing files...")
    /// Confirm Password
    public static let confirmPassword = L10n.tr("Localizable", "ZipExport.ConfirmPassword", fallback: "Confirm Password")
    /// Continue
    public static let `continue` = L10n.tr("Localizable", "ZipExport.Continue", fallback: "Continue")
    /// Decrypting %@ of %@...
    public static func decrypting(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "ZipExport.Decrypting", String(describing: p1), String(describing: p2), fallback: "Decrypting %@ of %@...")
    }
    /// Enter Password
    public static let enterPassword = L10n.tr("Localizable", "ZipExport.EnterPassword", fallback: "Enter Password")
    /// Error creating zip: %@
    public static func error(_ p1: Any) -> String {
      return L10n.tr("Localizable", "ZipExport.Error", String(describing: p1), fallback: "Error creating zip: %@")
    }
    /// Please keep your phone unlocked to complete this operation
    public static let keepPhoneOpen = L10n.tr("Localizable", "ZipExport.KeepPhoneOpen", fallback: "Please keep your phone unlocked to complete this operation")
    /// Passwords do not match
    public static let passwordMismatch = L10n.tr("Localizable", "ZipExport.PasswordMismatch", fallback: "Passwords do not match")
    /// Zip file password
    public static let passwordPlaceholder = L10n.tr("Localizable", "ZipExport.PasswordPlaceholder", fallback: "Zip file password")
    /// Preparing Encrypted Zip
    public static let preparing = L10n.tr("Localizable", "ZipExport.Preparing", fallback: "Preparing Encrypted Zip")
    /// ZipExport - Encrypted Zip Export Feature
    public static let shareDecrypted = L10n.tr("Localizable", "ZipExport.ShareDecrypted", fallback: "Share Decrypted")
    /// Share as Encrypted Zip
    public static let shareEncryptedZip = L10n.tr("Localizable", "ZipExport.ShareEncryptedZip", fallback: "Share as Encrypted Zip")
    /// Share Zip
    public static let shareZip = L10n.tr("Localizable", "ZipExport.ShareZip", fallback: "Share Zip")
  }
  public enum ZipExportError {
    /// Export was interrupted because the app was in the background too long. Please return to the app and try again.
    public static let backgroundTimeExpired = L10n.tr("Localizable", "ZipExportError.BackgroundTimeExpired", fallback: "Export was interrupted because the app was in the background too long. Please return to the app and try again.")
    /// Failed to decrypt media: %@. Please update the app to the latest version if you haven't already.
    public static func decryptionFailed(_ p1: Any) -> String {
      return L10n.tr("Localizable", "ZipExportError.DecryptionFailed", String(describing: p1), fallback: "Failed to decrypt media: %@. Please update the app to the latest version if you haven't already.")
    }
    /// Failed to create export directory: %@
    public static func directoryCreationFailed(_ p1: Any) -> String {
      return L10n.tr("Localizable", "ZipExportError.DirectoryCreationFailed", String(describing: p1), fallback: "Failed to create export directory: %@")
    }
    /// Password cannot be empty.
    public static let emptyPassword = L10n.tr("Localizable", "ZipExportError.EmptyPassword", fallback: "Password cannot be empty.")
    /// ZipExport Error Messages
    public static let noMediaToExport = L10n.tr("Localizable", "ZipExportError.NoMediaToExport", fallback: "No media selected for export.")
    /// Failed to create zip file: %@
    public static func zipCreationFailed(_ p1: Any) -> String {
      return L10n.tr("Localizable", "ZipExportError.ZipCreationFailed", String(describing: p1), fallback: "Failed to create zip file: %@")
    }
  }
}
// swiftlint:enable explicit_type_interface function_parameter_count identifier_name line_length
// swiftlint:enable nesting type_body_length type_name vertical_whitespace_opening_braces

// MARK: - Implementation Details

extension L10n {
  private static func tr(_ table: String, _ key: String, _ args: CVarArg..., fallback value: String) -> String {
    let format = BundleToken.bundle.localizedString(forKey: key, value: value, table: table)
    return String(format: format, locale: Locale.current, arguments: args)
  }
}

// swiftlint:disable convenience_type
private final class BundleToken {
  static let bundle: Bundle = {
    #if SWIFT_PACKAGE
    return Bundle.module
    #else
    return Bundle(for: BundleToken.self)
    #endif
  }()
}
// swiftlint:enable convenience_type
