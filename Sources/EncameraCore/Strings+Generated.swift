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
  /// Plural format key: "%#@image_count@"
  public static func imageS(_ p1: Int) -> String {
    return L10n.tr("Localizable", "%@ Image(s)", p1, fallback: "Plural format key: \"%#@image_count@\"")
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
  /// Cancel
  public static let cancel = L10n.tr("Localizable", "Cancel", fallback: "Cancel")
  /// ShareViewController.swift
  public static let cannotHandleMedia = L10n.tr("Localizable", "Cannot handle media", fallback: "Cannot handle media")
  /// I Want to Choose Another Destination Album
  public static let changeKeyAlbum = L10n.tr("Localizable", "Change Key Album", fallback: "I Want to Choose Another Destination Album")
  /// Change Password
  public static let changePassword = L10n.tr("Localizable", "Change Password", fallback: "Change Password")
  /// Check that the same key that was used to encrypt this media is set as the active key.
  public static let checkThatTheSameKeyThatWasUsedToEncryptThisMediaIsSetAsTheActiveKey = L10n.tr("Localizable", "Check that the same key that was used to encrypt this media is set as the active key.", fallback: "Check that the same key that was used to encrypt this media is set as the active key.")
  /// Choose your storage
  public static let chooseYourStorage = L10n.tr("Localizable", "ChooseYourStorage", fallback: "Choose your storage")
  /// Choose where to securely save your images from now on.
  public static let chooseYourStorageDescription = L10n.tr("Localizable", "ChooseYourStorageDescription", fallback: "Choose where to securely save your images from now on.")
  /// Close
  public static let close = L10n.tr("Localizable", "Close", fallback: "Close")
  /// Confirm adding key
  public static let confirmAddingKey = L10n.tr("Localizable", "Confirm adding key", fallback: "Confirm adding key")
  /// Confirm Pin Code
  public static let confirmPinCode = L10n.tr("Localizable", "ConfirmPinCode", fallback: "Confirm Pin Code")
  /// Confirm Storage
  public static let confirmStorage = L10n.tr("Localizable", "ConfirmStorage", fallback: "Confirm Storage")
  /// ./Encamera/Tutorial/ChooseStorageModal.swift
  public static let congratulations = L10n.tr("Localizable", "Congratulations!", fallback: "Congratulations!")
  /// Contact
  public static let contact = L10n.tr("Localizable", "Contact", fallback: "Contact")
  /// Picture taken overlay
  public static let coolPicture = L10n.tr("Localizable", "CoolPicture", fallback: "That's a cool picture!")
  /// Copied to Clipboard
  public static let copiedToClipboard = L10n.tr("Localizable", "Copied to Clipboard", fallback: "Copied to Clipboard")
  /// ./Encamera/ImageViewing/MovieViewing.swift
  public static func couldNotDecryptMovie(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Could not decrypt movie: %@", String(describing: p1), fallback: "Could not decrypt movie: %@")
  }
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
  /// Decrypting...
  public static let decrypting = L10n.tr("Localizable", "Decrypting...", fallback: "Decrypting...")
  /// Decryption error: %@
  public static func decryptionError(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Decryption error: %@", String(describing: p1), fallback: "Decryption error: %@")
  }
  /// ./EncameraCore/Constants/AppConstants.swift
  public static let defaultAlbumName = L10n.tr("Localizable", "DefaultAlbumName", fallback: "My Album")
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
  /// Do you want to delete this key forever? All media will remain saved.
  public static let doYouWantToDeleteThisKeyForeverAllMediaWillRemainSaved = L10n.tr("Localizable", "Do you want to delete this key forever? All media will remain saved.", fallback: "Do you want to delete this key forever? All media will remain saved.")
  /// Done
  public static let done = L10n.tr("Localizable", "Done", fallback: "Done")
  /// Done!
  public static let doneOnboarding = L10n.tr("Localizable", "DoneOnboarding", fallback: "Done!")
  /// Downloading from iCloud
  public static let downloadingFromICloud = L10n.tr("Localizable", "Downloading from iCloud", fallback: "Downloading from iCloud")
  /// Are you done importing images?
  public static let doYouWantToDeleteNotImported = L10n.tr("Localizable", "DoYouWantToDeleteNotImported", fallback: "Are you done importing images?")
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
  /// Encamera encrypts everything, keeping your media safe from unwanted eyes.
  public static let encameraEncryptsAllDataItCreatesKeepingYourDataSafeFromThePryingEyesOfAIMediaAnalysisAndOtherViolationsOfPrivacy = L10n.tr("Localizable", "Encamera encrypts all data it creates, keeping your data safe from the prying eyes of AI, media analysis, and other violations of privacy.", fallback: "Encamera encrypts everything, keeping your media safe from unwanted eyes.")
  /// Open Source
  public static let encameraIsOpenSource = L10n.tr("Localizable", "EncameraIsOpenSource", fallback: "Open Source")
  /// ./Encamera/Styles/ViewModifiers/ButtonViewModifier.swift
  public static let encryptEverything = L10n.tr("Localizable", "Encrypt Everything", fallback: "Encrypt Everything")
  /// Encrypting
  public static let encrypting = L10n.tr("Localizable", "Encrypting", fallback: "Encrypting")
  /// Encryption Key
  public static let encryptionKey = L10n.tr("Localizable", "Encryption Key", fallback: "Encryption Key")
  /// Your media is safely secured behind a key and stored locally on your device or iCloud
  public static let encryptionExplanation = L10n.tr("Localizable", "EncryptionExplanation", fallback: "Your media is safely secured behind a key and stored locally on your device or iCloud")
  /// Enter Password
  public static let enterPassword = L10n.tr("Localizable", "Enter Password", fallback: "Enter Password")
  /// Enter Promo Code
  public static let enterPromoCode = L10n.tr("Localizable", "Enter Promo Code", fallback: "Enter Promo Code")
  /// Enter your password
  public static let enterYourPassword = L10n.tr("Localizable", "EnterYourPassword", fallback: "Enter your password")
  /// Erase
  public static let erase = L10n.tr("Localizable", "Erase", fallback: "Erase")
  /// Erase all data
  public static let eraseAllData = L10n.tr("Localizable", "Erase all data", fallback: "Erase all data")
  /// Erase app data
  public static let eraseAppData = L10n.tr("Localizable", "Erase app data", fallback: "Erase app data")
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
  /// Face ID
  public static let faceID = L10n.tr("Localizable", "Face ID", fallback: "Face ID")
  /// ./Encamera/Styles/ViewModifiers/PurchaseOptionViewModifier.swift
  public static let familyShareable = L10n.tr("Localizable", "Family Shareable", fallback: "Family Shareable")
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
  /// Follow @encamera_app on Twitter
  public static let followUs = L10n.tr("Localizable", "FollowUs", fallback: "Follow @encamera_app on Twitter")
  /// Free Trial
  public static let freeTrial = L10n.tr("Localizable", "Free Trial", fallback: "Free Trial")
  /// 7 days free, then %@
  public static func freeTrialTerms(_ p1: Any) -> String {
    return L10n.tr("Localizable", "FreeTrialTerms", String(describing: p1), fallback: "7 days free, then %@")
  }
  /// TweetToShareView.swift
  public static let getOneYearFree = L10n.tr("Localizable", "GetOneYearFree", fallback: "Get 1 Year Free!")
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
  /// IMAGE SAVED TO ALBUM
  public static let imageSavedToAlbum = L10n.tr("Localizable", "ImageSavedToAlbum", fallback: "IMAGE SAVED TO ALBUM")
  /// Import
  public static let `import` = L10n.tr("Localizable", "Import", fallback: "Import")
  /// Import media
  public static let importMedia = L10n.tr("Localizable", "Import media", fallback: "Import media")
  /// Import the selected images to your currently active key album
  public static let importSelectedImages = L10n.tr("Localizable", "ImportSelectedImages", fallback: "Import the selected images to your currently active key album")
  /// Add Encamera to your lock screen to quickly take pictures
  public static let installWidgetBody = L10n.tr("Localizable", "InstallWidgetBody", fallback: "Add Encamera to your lock screen to quickly take pictures")
  /// Add Widget
  public static let installWidgetButtonText = L10n.tr("Localizable", "InstallWidgetButtonText", fallback: "Add Widget")
  /// Install Lock Screen Widget
  public static let installWidgetTitle = L10n.tr("Localizable", "InstallWidgetTitle", fallback: "Install Lock Screen Widget")
  /// Your media is safely secured behind a key and stored locally on your device or iCloud.
  public static let introStorageExplanation = L10n.tr("Localizable", "IntroStorageExplanation", fallback: "Your media is safely secured behind a key and stored locally on your device or iCloud.")
  /// Invalid Password
  public static let invalidPassword = L10n.tr("Localizable", "Invalid Password", fallback: "Invalid Password")
  /// Join Telegram Group
  public static let joinTelegramGroup = L10n.tr("Localizable", "Join Telegram Group", fallback: "Join Telegram Group")
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
  /// Key-Based Encryption
  public static let keyBasedEncryption = L10n.tr("Localizable", "KeyBasedEncryption", fallback: "Key-Based Encryption")
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
  /// Local
  public static let local = L10n.tr("Localizable", "Local", fallback: "Local")
  /// Choose how you want to access your private albums.
  public static let loginMethodDescription = L10n.tr("Localizable", "LoginMethodDescription", fallback: "Choose how you want to access your private albums.")
  /// ./Encamera/CameraView/CameraView.swift
  public static let missingCameraAccess = L10n.tr("Localizable", "Missing camera access.", fallback: "Missing camera access.")
  /// ./Encamera/AuthenticationView/AuthenticationView.swift
  public static let missingPassword = L10n.tr("Localizable", "Missing password", fallback: "Missing password")
  /// Upgrade to premium to unlock unlimited photos
  public static let modalUpgradeText = L10n.tr("Localizable", "ModalUpgradeText", fallback: "Upgrade to premium to unlock unlimited photos")
  /// MOST POPULAR
  public static let mostPopular = L10n.tr("Localizable", "MostPopular", fallback: "MOST POPULAR")
  /// Move Album
  public static let moveAlbumStorage = L10n.tr("Localizable", "MoveAlbumStorage", fallback: "Move Album")
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
  /// Nobody can access your data except you.
  public static let noTrackingExplanation = L10n.tr("Localizable", "NoTrackingExplanation", fallback: "Nobody can access your data except you.")
  /// Your Data is Secure
  public static let noTrackingOnboardingExplanation = L10n.tr("Localizable", "NoTrackingOnboardingExplanation", fallback: "Your Data is Secure")
  /// OK
  public static let ok = L10n.tr("Localizable", "OK", fallback: "OK")
  /// Privacy-First Camera
  public static let onboardingIntroHeadingText1 = L10n.tr("Localizable", "OnboardingIntroHeadingText1", fallback: "Privacy-First Camera")
  /// Encamera encrypts everything, keeping your media safe from unwanted eyes.
  public static let onboardingIntroSubheadingText = L10n.tr("Localizable", "OnboardingIntroSubheadingText", fallback: "Encamera encrypts everything, keeping your media safe from unwanted eyes.")
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
  /// Open settings to allow camera access permission
  public static let openSettingsToAllowCameraAccessPermission = L10n.tr("Localizable", "Open settings to allow camera access permission", fallback: "Open settings to allow camera access permission")
  /// Open Source
  public static let openSource = L10n.tr("Localizable", "Open Source", fallback: "Open Source")
  /// Open Settings
  public static let openSettings = L10n.tr("Localizable", "OpenSettings", fallback: "Open Settings")
  /// Encamera's core functionality is open sourced, meaning you can see the code that's making your photos safe.
  public static let openSourceExplanation = L10n.tr("Localizable", "OpenSourceExplanation", fallback: "Encamera's core functionality is open sourced, meaning you can see the code that's making your photos safe.")
  /// Or
  public static let or = L10n.tr("Localizable", "Or", fallback: "Or")
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
  /// Passwords do not match.
  public static let passwordsDoNotMatch = L10n.tr("Localizable", "Passwords do not match.", fallback: "Passwords do not match.")
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
  /// Pin Code Does Not Match
  public static let pinCodeDoesNotMatch = L10n.tr("Localizable", "PinCodeDoesNotMatch", fallback: "Pin Code Does Not Match")
  /// Pincodes are not the same
  public static let pinCodeMismatch = L10n.tr("Localizable", "PinCodeMismatch", fallback: "Pincodes are not the same")
  /// Please select a storage location.
  public static let pleaseSelectAStorageLocation = L10n.tr("Localizable", "Please select a storage location.", fallback: "Please select a storage location.")
  /// Please enter a name for the album
  public static let pleaseEnterAnAlbumName = L10n.tr("Localizable", "PleaseEnterAnAlbumName", fallback: "Please enter a name for the album")
  /// premium
  public static let premium = L10n.tr("Localizable", "premium", fallback: "premium")
  /// Unlock all of these amazing benefits today
  public static let premiumUnlockTheseBenefits = L10n.tr("Localizable", "PremiumUnlockTheseBenefits", fallback: "Unlock all of these amazing benefits today")
  /// Privacy Policy
  public static let privacyPolicy = L10n.tr("Localizable", "Privacy Policy", fallback: "Privacy Policy")
  /// ./Encamera/Onboarding/OnboardingView.swift
  public static let profileSetup = L10n.tr("Localizable", "ProfileSetup", fallback: "PROFILE SETUP")
  /// Widget
  public static let quicklyTakePictures = L10n.tr("Localizable", "QuicklyTakePictures", fallback: "Quickly take pictures and video.")
  /// Rename
  public static let rename = L10n.tr("Localizable", "Rename", fallback: "Rename")
  /// Repeat Password
  public static let repeatPassword = L10n.tr("Localizable", "Repeat Password", fallback: "Repeat Password")
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
  /// Select Login Method
  public static let selectLoginMethod = L10n.tr("Localizable", "Select Login Method", fallback: "Select Login Method")
  /// Select Storage
  public static let selectStorage = L10n.tr("Localizable", "Select Storage", fallback: "Select Storage")
  /// Select an Option
  public static let selectAnOption = L10n.tr("Localizable", "SelectAnOption", fallback: "Select an Option")
  /// Set as Active Key
  public static let setAsActiveKey = L10n.tr("Localizable", "Set as Active Key", fallback: "Set as Active Key")
  /// Set Password
  public static let setPassword = L10n.tr("Localizable", "Set Password", fallback: "Set Password")
  /// Set a password to access the app. Be sure to store it in a safe place – you cannot recover it later.
  public static let setAPasswordWarning = L10n.tr("Localizable", "SetAPasswordWarning", fallback: "Set a password to access the app. Be sure to store it in a safe place – you cannot recover it later.")
  /// Set Pin Code
  public static let setPinCode = L10n.tr("Localizable", "SetPinCode", fallback: "Set Pin Code")
  /// This pin will be used to securely login in your app. Make sure you remember it!
  public static let setPinCodeSubtitle = L10n.tr("Localizable", "SetPinCodeSubtitle", fallback: "This pin will be used to securely login in your app. Make sure you remember it!")
  /// Settings
  public static let settings = L10n.tr("Localizable", "Settings", fallback: "Settings")
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
  public static let startTrialOffer = L10n.tr("Localizable", "Start trial offer", fallback: "Start trial offer")
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
  /// TAKE YOUR FIRST PICTURE
  public static let takeYourFirstPicture = L10n.tr("Localizable", "TakeYourFirstPicture", fallback: "TAKE YOUR FIRST PICTURE")
  /// Tap the 
  public static let tapThe = L10n.tr("Localizable", "Tap the ", fallback: "Tap the ")
  /// Tap to Upgrade
  public static let tapToUpgrade = L10n.tr("Localizable", "Tap to Upgrade", fallback: "Tap to Upgrade")
  /// Tap to Tweet!
  public static let tapToTweet = L10n.tr("Localizable", "TapToTweet", fallback: "Tap to Tweet!")
  /// Get early access to beta features and give feedback
  public static let telegramGroupJoinBody = L10n.tr("Localizable", "TelegramGroupJoinBody", fallback: "Get early access to beta features and give feedback")
  /// Join Group
  public static let telegramGroupJoinButtonText = L10n.tr("Localizable", "TelegramGroupJoinButtonText", fallback: "Join Group")
  /// Join Telegram Group
  public static let telegramGroupJoinTitle = L10n.tr("Localizable", "TelegramGroupJoinTitle", fallback: "Join Telegram Group")
  /// Terms of Use
  public static let termsOfUse = L10n.tr("Localizable", "Terms of Use", fallback: "Terms of Use")
  /// Thank you for your support!
  public static let thankYouForYourSupport = L10n.tr("Localizable", "Thank you for your support!", fallback: "Thank you for your support!")
  /// ./Encamera/ImageViewing/DecryptErrorExplanation.swift
  public static let theMediaYouTriedToOpenCouldNotBeDecrypted = L10n.tr("Localizable", "The media you tried to open could not be decrypted.", fallback: "The media you tried to open could not be decrypted.")
  /// This will save the media to your library.
  public static let thisWillSaveTheMediaToYourLibrary = L10n.tr("Localizable", "This will save the media to your library.", fallback: "This will save the media to your library.")
  /// ./EncameraCore/Utils/AuthManager.swift
  public static let touchID = L10n.tr("Localizable", "Touch ID", fallback: "Touch ID")
  /// Get 100%% off the $9.99 yearly subscription fee!
  /// 
  ///  You only need to do two things:
  /// 1. Follow @encamera_app
  /// 2. Tap the link below to tweet about Encamera
  public static let tweetToRedeemOfferExplanation = L10n.tr("Localizable", "TweetToRedeemOfferExplanation", fallback: "Get 100%% off the $9.99 yearly subscription fee!\n\n You only need to do two things:\n1. Follow @encamera_app\n2. Tap the link below to tweet about Encamera")
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
  /// Use Password
  public static let usePassword = L10n.tr("Localizable", "Use Password", fallback: "Use Password")
  /// Use PIN instead
  public static let usePINInstead = L10n.tr("Localizable", "Use PIN instead", fallback: "Use PIN instead")
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
  /// You will find all of your photos and videos grouped in the “Albums”
  public static let whereToFindYourPictures = L10n.tr("Localizable", "WhereToFindYourPictures", fallback: "You will find all of your photos and videos grouped in the “Albums”")
  /// Why Encrypt Media?
  public static let whyEncryptMedia = L10n.tr("Localizable", "Why Encrypt Media?", fallback: "Why Encrypt Media?")
  /// You have an existing password for this device.
  public static let youHaveAnExistingPasswordForThisDevice = L10n.tr("Localizable", "You have an existing password for this device.", fallback: "You have an existing password for this device.")
  /// You took your first photo! 📸 🥳
  public static let youTookYourFirstPhoto📸🥳 = L10n.tr("Localizable", "You took your first photo! 📸 🥳", fallback: "You took your first photo! 📸 🥳")
  /// Your Keys
  public static let yourKeys = L10n.tr("Localizable", "Your Keys", fallback: "Your Keys")
  /// Afterwards, you will be sent a promo code via DM that you can redeem in the app.
  public static let youWillBeSentAPromoCode = L10n.tr("Localizable", "YouWillBeSentAPromoCode", fallback: "Afterwards, you will be sent a promo code via DM that you can redeem in the app.")
  public enum EnterTheNameOfTheKeyToDeleteItForever {
    /// Enter the name of the key to delete it forever. All media will remain saved.
    public static let allMediaWillRemainSaved = L10n.tr("Localizable", "Enter the name of the key to delete it forever. All media will remain saved.", fallback: "Enter the name of the key to delete it forever. All media will remain saved.")
  }
  public enum ErrorDeletingKey {
    /// ./Encamera/KeyManagement/AlbumDetailView.swift
    public static let pleaseTryAgain = L10n.tr("Localizable", "Error deleting key. Please try again.", fallback: "Error deleting key. Please try again.")
  }
  public enum ErrorDeletingKeyAndAssociatedFiles {
    /// Error deleting key and associated files. Please try again or try to delete files manually via the Files app.
    public static let pleaseTryAgainOrTryToDeleteFilesManuallyViaTheFilesApp = L10n.tr("Localizable", "Error deleting key and associated files. Please try again or try to delete files manually via the Files app.", fallback: "Error deleting key and associated files. Please try again or try to delete files manually via the Files app.")
  }
  public enum KeyCopiedToClipboard {
    /// Key copied to clipboard. Store this in a password manager or other secure place.
    public static let storeThisInAPasswordManagerOrOtherSecurePlace = L10n.tr("Localizable", "Key copied to clipboard. Store this in a password manager or other secure place.", fallback: "Key copied to clipboard. Store this in a password manager or other secure place.")
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
