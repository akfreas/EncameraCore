//
//  OSStatusChecker.swift
//  Encamera
//
//  Created by Alexander Freas on 20.07.22.
//

import Foundation
func determineOSStatus(status: OSStatus) {
    #if DEBUG
    var printString = ""
    switch status {
    case errSecSuccess: printString += "errSecSuccess"
    case errSecUnimplemented: printString += "errSecUnimplemented"
    case errSecDiskFull: printString += "errSecDiskFull"
    
    case errSecIO: printString += "errSecIO"
    case errSecOpWr: printString += "errSecOpWr"
    case errSecParam: printString += "errSecParam"
    case errSecWrPerm: printString += "errSecWrPerm"
    case errSecAllocate: printString += "errSecAllocate"
    case errSecUserCanceled: printString += "errSecUserCanceled"
    case errSecBadReq: printString += "errSecBadReq"

    case errSecInternalComponent: printString += "errSecInternalComponent"
    case errSecCoreFoundationUnknown: printString += "errSecCoreFoundationUnknown"

    case errSecMissingEntitlement: printString += "errSecMissingEntitlement"
    case errSecRestrictedAPI: printString += "errSecRestrictedAPI"

    case errSecNotAvailable: printString += "errSecNotAvailable"
    case errSecReadOnly: printString += "errSecReadOnly"
    case errSecAuthFailed: printString += "errSecAuthFailed"
    case errSecNoSuchKeychain: printString += "errSecNoSuchKeychain"
    case errSecInvalidKeychain: printString += "errSecInvalidKeychain"
    case errSecDuplicateKeychain: printString += "errSecDuplicateKeychain"
    case errSecDuplicateCallback: printString += "errSecDuplicateCallback"
    case errSecInvalidCallback: printString += "errSecInvalidCallback"
    case errSecDuplicateItem: printString += "errSecDuplicateItem"
    case errSecItemNotFound: printString += "errSecItemNotFound"
    case errSecBufferTooSmall: printString += "errSecBufferTooSmall"
    case errSecDataTooLarge: printString += "errSecDataTooLarge"
    case errSecNoSuchAttr: printString += "errSecNoSuchAttr"
    case errSecInvalidItemRef: printString += "errSecInvalidItemRef"
    case errSecInvalidSearchRef: printString += "errSecInvalidSearchRef"
    case errSecNoSuchClass: printString += "errSecNoSuchClass"
    case errSecNoDefaultKeychain: printString += "errSecNoDefaultKeychain"
    case errSecInteractionNotAllowed: printString += "errSecInteractionNotAllowed"
    case errSecReadOnlyAttr: printString += "errSecReadOnlyAttr"
    case errSecWrongSecVersion: printString += "errSecWrongSecVersion"
    case errSecKeySizeNotAllowed: printString += "errSecKeySizeNotAllowed"
    case errSecNoStorageModule: printString += "errSecNoStorageModule"
    case errSecNoCertificateModule: printString += "errSecNoCertificateModule"
    case errSecNoPolicyModule: printString += "errSecNoPolicyModule"
    case errSecInteractionRequired: printString += "errSecInteractionRequired"
    case errSecDataNotAvailable: printString += "errSecDataNotAvailable"
    case errSecDataNotModifiable: printString += "errSecDataNotModifiable"
    case errSecCreateChainFailed: printString += "errSecCreateChainFailed"
    case errSecInvalidPrefsDomain: printString += "errSecInvalidPrefsDomain"
    case errSecInDarkWake: printString += "errSecInDarkWake"

    case errSecACLNotSimple: printString += "errSecACLNotSimple"
    case errSecPolicyNotFound: printString += "errSecPolicyNotFound"
    case errSecInvalidTrustSetting: printString += "errSecInvalidTrustSetting"
    case errSecNoAccessForItem: printString += "errSecNoAccessForItem"
    case errSecInvalidOwnerEdit: printString += "errSecInvalidOwnerEdit"
    case errSecTrustNotAvailable: printString += "errSecTrustNotAvailable"
    case errSecUnsupportedFormat: printString += "errSecUnsupportedFormat"
    case errSecUnknownFormat: printString += "errSecUnknownFormat"
    case errSecKeyIsSensitive: printString += "errSecKeyIsSensitive"
    case errSecMultiplePrivKeys: printString += "errSecMultiplePrivKeys"
    case errSecPassphraseRequired: printString += "errSecPassphraseRequired"
    case errSecInvalidPasswordRef: printString += "errSecInvalidPasswordRef"
    case errSecInvalidTrustSettings: printString += "errSecInvalidTrustSettings"
    case errSecNoTrustSettings: printString += "errSecNoTrustSettings"
    case errSecNotSigner: printString += "errSecNotSigner"

    case errSecDecode: printString += "errSecDecode"

    case errSecServiceNotAvailable: printString += "errSecServiceNotAvailable"
    case errSecInsufficientClientID: printString += "errSecInsufficientClientID"
    case errSecDeviceReset: printString += "errSecDeviceReset"
    case errSecDeviceFailed: printString += "errSecDeviceFailed"
    case errSecAppleAddAppACLSubject: printString += "errSecAppleAddAppACLSubject"
    case errSecApplePublicKeyIncomplete: printString += "errSecApplePublicKeyIncomplete"
    case errSecAppleSignatureMismatch: printString += "errSecAppleSignatureMismatch"
    case errSecAppleInvalidKeyStartDate: printString += "errSecAppleInvalidKeyStartDate"
    case errSecAppleInvalidKeyEndDate: printString += "errSecAppleInvalidKeyEndDate"
    case errSecConversionError: printString += "errSecConversionError"
    case errSecQuotaExceeded: printString += "errSecQuotaExceeded"
    case errSecFileTooBig: printString += "errSecFileTooBig"
    case errSecInvalidDatabaseBlob: printString += "errSecInvalidDatabaseBlob"
    case errSecInvalidKeyBlob: printString += "errSecInvalidKeyBlob"
    case errSecIncompatibleDatabaseBlob: printString += "errSecIncompatibleDatabaseBlob"
    case errSecIncompatibleKeyBlob: printString += "errSecIncompatibleKeyBlob"
    case errSecHostNameMismatch: printString += "errSecHostNameMismatch"
    case errSecUnknownCriticalExtensionFlag: printString += "errSecUnknownCriticalExtensionFlag"
    case errSecNoBasicConstraints: printString += "errSecNoBasicConstraints"
    case errSecNoBasicConstraintsCA: printString += "errSecNoBasicConstraintsCA"
    case errSecInvalidAuthorityKeyID: printString += "errSecInvalidAuthorityKeyID"
    case errSecInvalidSubjectKeyID: printString += "errSecInvalidSubjectKeyID"
    case errSecInvalidKeyUsageForPolicy: printString += "errSecInvalidKeyUsageForPolicy"
    case errSecInvalidExtendedKeyUsage: printString += "errSecInvalidExtendedKeyUsage"
    case errSecInvalidIDLinkage: printString += "errSecInvalidIDLinkage"
    case errSecPathLengthConstraintExceeded: printString += "errSecPathLengthConstraintExceeded"
    case errSecInvalidRoot: printString += "errSecInvalidRoot"
    case errSecCRLExpired: printString += "errSecCRLExpired"
    case errSecCRLNotValidYet: printString += "errSecCRLNotValidYet"
    case errSecCRLNotFound: printString += "errSecCRLNotFound"
    case errSecCRLServerDown: printString += "errSecCRLServerDown"
    case errSecCRLBadURI: printString += "errSecCRLBadURI"
    case errSecUnknownCertExtension: printString += "errSecUnknownCertExtension"
    case errSecUnknownCRLExtension: printString += "errSecUnknownCRLExtension"
    case errSecCRLNotTrusted: printString += "errSecCRLNotTrusted"
    case errSecCRLPolicyFailed: printString += "errSecCRLPolicyFailed"
    case errSecIDPFailure: printString += "errSecIDPFailure"
    case errSecSMIMEEmailAddressesNotFound: printString += "errSecSMIMEEmailAddressesNotFound"
    case errSecSMIMEBadExtendedKeyUsage: printString += "errSecSMIMEBadExtendedKeyUsage"
    case errSecSMIMEBadKeyUsage: printString += "errSecSMIMEBadKeyUsage"
    case errSecSMIMEKeyUsageNotCritical: printString += "errSecSMIMEKeyUsageNotCritical"
    case errSecSMIMENoEmailAddress: printString += "errSecSMIMENoEmailAddress"
    case errSecSMIMESubjAltNameNotCritical: printString += "errSecSMIMESubjAltNameNotCritical"
    case errSecSSLBadExtendedKeyUsage: printString += "errSecSSLBadExtendedKeyUsage"
    case errSecOCSPBadResponse: printString += "errSecOCSPBadResponse"
    case errSecOCSPBadRequest: printString += "errSecOCSPBadRequest"
    case errSecOCSPUnavailable: printString += "errSecOCSPUnavailable"
    case errSecOCSPStatusUnrecognized: printString += "errSecOCSPStatusUnrecognized"
    case errSecEndOfData: printString += "errSecEndOfData"
    case errSecIncompleteCertRevocationCheck: printString += "errSecIncompleteCertRevocationCheck"
    case errSecNetworkFailure: printString += "errSecNetworkFailure"
    case errSecOCSPNotTrustedToAnchor: printString += "errSecOCSPNotTrustedToAnchor"
    case errSecRecordModified: printString += "errSecRecordModified"
    case errSecOCSPSignatureError: printString += "errSecOCSPSignatureError"
    case errSecOCSPNoSigner: printString += "errSecOCSPNoSigner"
    case errSecOCSPResponderMalformedReq: printString += "errSecOCSPResponderMalformedReq"
    case errSecOCSPResponderInternalError: printString += "errSecOCSPResponderInternalError"
    case errSecOCSPResponderTryLater: printString += "errSecOCSPResponderTryLater"
    case errSecOCSPResponderSignatureRequired: printString += "errSecOCSPResponderSignatureRequired"
    case errSecOCSPResponderUnauthorized: printString += "errSecOCSPResponderUnauthorized"
    case errSecOCSPResponseNonceMismatch: printString += "errSecOCSPResponseNonceMismatch"
    case errSecCodeSigningBadCertChainLength: printString += "errSecCodeSigningBadCertChainLength"
    case errSecCodeSigningNoBasicConstraints: printString += "errSecCodeSigningNoBasicConstraints"
    case errSecCodeSigningBadPathLengthConstraint: printString += "errSecCodeSigningBadPathLengthConstraint"
    case errSecCodeSigningNoExtendedKeyUsage: printString += "errSecCodeSigningNoExtendedKeyUsage"
    case errSecCodeSigningDevelopment: printString += "errSecCodeSigningDevelopment"
    case errSecResourceSignBadCertChainLength: printString += "errSecResourceSignBadCertChainLength"
    case errSecResourceSignBadExtKeyUsage: printString += "errSecResourceSignBadExtKeyUsage"
    case errSecTrustSettingDeny: printString += "errSecTrustSettingDeny"
    case errSecInvalidSubjectName: printString += "errSecInvalidSubjectName"
    case errSecUnknownQualifiedCertStatement: printString += "errSecUnknownQualifiedCertStatement"
    case errSecMobileMeRequestQueued: printString += "errSecMobileMeRequestQueued"
    case errSecMobileMeRequestRedirected: printString += "errSecMobileMeRequestRedirected"
    case errSecMobileMeServerError: printString += "errSecMobileMeServerError"
    case errSecMobileMeServerNotAvailable: printString += "errSecMobileMeServerNotAvailable"
    case errSecMobileMeServerAlreadyExists: printString += "errSecMobileMeServerAlreadyExists"
    case errSecMobileMeServerServiceErr: printString += "errSecMobileMeServerServiceErr"
    case errSecMobileMeRequestAlreadyPending: printString += "errSecMobileMeRequestAlreadyPending"
    case errSecMobileMeNoRequestPending: printString += "errSecMobileMeNoRequestPending"
    case errSecMobileMeCSRVerifyFailure: printString += "errSecMobileMeCSRVerifyFailure"
    case errSecMobileMeFailedConsistencyCheck: printString += "errSecMobileMeFailedConsistencyCheck"
    case errSecNotInitialized: printString += "errSecNotInitialized"
    case errSecInvalidHandleUsage: printString += "errSecInvalidHandleUsage"
    case errSecPVCReferentNotFound: printString += "errSecPVCReferentNotFound"
    case errSecFunctionIntegrityFail: printString += "errSecFunctionIntegrityFail"
    case errSecInternalError: printString += "errSecInternalError"
    case errSecMemoryError: printString += "errSecMemoryError"
    case errSecInvalidData: printString += "errSecInvalidData"
    case errSecMDSError: printString += "errSecMDSError"
    case errSecInvalidPointer: printString += "errSecInvalidPointer"
    case errSecSelfCheckFailed: printString += "errSecSelfCheckFailed"
    case errSecFunctionFailed: printString += "errSecFunctionFailed"
    case errSecModuleManifestVerifyFailed: printString += "errSecModuleManifestVerifyFailed"
    case errSecInvalidGUID: printString += "errSecInvalidGUID"
    case errSecInvalidHandle: printString += "errSecInvalidHandle"
    case errSecInvalidDBList: printString += "errSecInvalidDBList"
    case errSecInvalidPassthroughID: printString += "errSecInvalidPassthroughID"
    case errSecInvalidNetworkAddress: printString += "errSecInvalidNetworkAddress"
    case errSecCRLAlreadySigned: printString += "errSecCRLAlreadySigned"
    case errSecInvalidNumberOfFields: printString += "errSecInvalidNumberOfFields"
    case errSecVerificationFailure: printString += "errSecVerificationFailure"
    case errSecUnknownTag: printString += "errSecUnknownTag"
    case errSecInvalidSignature: printString += "errSecInvalidSignature"
    case errSecInvalidName: printString += "errSecInvalidName"
    case errSecInvalidCertificateRef: printString += "errSecInvalidCertificateRef"
    case errSecInvalidCertificateGroup: printString += "errSecInvalidCertificateGroup"
    case errSecTagNotFound: printString += "errSecTagNotFound"
    case errSecInvalidQuery: printString += "errSecInvalidQuery"
    case errSecInvalidValue: printString += "errSecInvalidValue"
    case errSecCallbackFailed: printString += "errSecCallbackFailed"
    case errSecACLDeleteFailed: printString += "errSecACLDeleteFailed"
    case errSecACLReplaceFailed: printString += "errSecACLReplaceFailed"
    case errSecACLAddFailed: printString += "errSecACLAddFailed"
    case errSecACLChangeFailed: printString += "errSecACLChangeFailed"
    case errSecInvalidAccessCredentials: printString += "errSecInvalidAccessCredentials"
    case errSecInvalidRecord: printString += "errSecInvalidRecord"
    case errSecInvalidACL: printString += "errSecInvalidACL"
    case errSecInvalidSampleValue: printString += "errSecInvalidSampleValue"
    case errSecIncompatibleVersion: printString += "errSecIncompatibleVersion"
    case errSecPrivilegeNotGranted: printString += "errSecPrivilegeNotGranted"
    case errSecInvalidScope: printString += "errSecInvalidScope"
    case errSecPVCAlreadyConfigured: printString += "errSecPVCAlreadyConfigured"
    case errSecInvalidPVC: printString += "errSecInvalidPVC"
    case errSecEMMLoadFailed: printString += "errSecEMMLoadFailed"
    case errSecEMMUnloadFailed: printString += "errSecEMMUnloadFailed"
    case errSecAddinLoadFailed: printString += "errSecAddinLoadFailed"
    case errSecInvalidKeyRef: printString += "errSecInvalidKeyRef"
    case errSecInvalidKeyHierarchy: printString += "errSecInvalidKeyHierarchy"
    case errSecAddinUnloadFailed: printString += "errSecAddinUnloadFailed"
    case errSecLibraryReferenceNotFound: printString += "errSecLibraryReferenceNotFound"
    case errSecInvalidAddinFunctionTable: printString += "errSecInvalidAddinFunctionTable"
    case errSecInvalidServiceMask: printString += "errSecInvalidServiceMask"
    case errSecModuleNotLoaded: printString += "errSecModuleNotLoaded"
    case errSecInvalidSubServiceID: printString += "errSecInvalidSubServiceID"
    case errSecAttributeNotInContext: printString += "errSecAttributeNotInContext"
    case errSecModuleManagerInitializeFailed: printString += "errSecModuleManagerInitializeFailed"
    case errSecModuleManagerNotFound: printString += "errSecModuleManagerNotFound"
    case errSecEventNotificationCallbackNotFound: printString += "errSecEventNotificationCallbackNotFound"
    case errSecInputLengthError: printString += "errSecInputLengthError"
    case errSecOutputLengthError: printString += "errSecOutputLengthError"
    case errSecPrivilegeNotSupported: printString += "errSecPrivilegeNotSupported"
    case errSecDeviceError: printString += "errSecDeviceError"
    case errSecAttachHandleBusy: printString += "errSecAttachHandleBusy"
    case errSecNotLoggedIn: printString += "errSecNotLoggedIn"
    case errSecAlgorithmMismatch: printString += "errSecAlgorithmMismatch"
    case errSecKeyUsageIncorrect: printString += "errSecKeyUsageIncorrect"
    case errSecKeyBlobTypeIncorrect: printString += "errSecKeyBlobTypeIncorrect"
    case errSecKeyHeaderInconsistent: printString += "errSecKeyHeaderInconsistent"
    case errSecUnsupportedKeyFormat: printString += "errSecUnsupportedKeyFormat"
    case errSecUnsupportedKeySize: printString += "errSecUnsupportedKeySize"
    case errSecInvalidKeyUsageMask: printString += "errSecInvalidKeyUsageMask"
    case errSecUnsupportedKeyUsageMask: printString += "errSecUnsupportedKeyUsageMask"
    case errSecInvalidKeyAttributeMask: printString += "errSecInvalidKeyAttributeMask"
    case errSecUnsupportedKeyAttributeMask: printString += "errSecUnsupportedKeyAttributeMask"
    case errSecInvalidKeyLabel: printString += "errSecInvalidKeyLabel"
    case errSecUnsupportedKeyLabel: printString += "errSecUnsupportedKeyLabel"
    case errSecInvalidKeyFormat: printString += "errSecInvalidKeyFormat"
    case errSecUnsupportedVectorOfBuffers: printString += "errSecUnsupportedVectorOfBuffers"
    case errSecInvalidInputVector: printString += "errSecInvalidInputVector"
    case errSecInvalidOutputVector: printString += "errSecInvalidOutputVector"
    case errSecInvalidContext: printString += "errSecInvalidContext"
    case errSecInvalidAlgorithm: printString += "errSecInvalidAlgorithm"
    case errSecInvalidAttributeKey: printString += "errSecInvalidAttributeKey"
    case errSecMissingAttributeKey: printString += "errSecMissingAttributeKey"
    case errSecInvalidAttributeInitVector: printString += "errSecInvalidAttributeInitVector"
    case errSecMissingAttributeInitVector: printString += "errSecMissingAttributeInitVector"
    case errSecInvalidAttributeSalt: printString += "errSecInvalidAttributeSalt"
    case errSecMissingAttributeSalt: printString += "errSecMissingAttributeSalt"
    case errSecInvalidAttributePadding: printString += "errSecInvalidAttributePadding"
    case errSecMissingAttributePadding: printString += "errSecMissingAttributePadding"
    case errSecInvalidAttributeRandom: printString += "errSecInvalidAttributeRandom"
    case errSecMissingAttributeRandom: printString += "errSecMissingAttributeRandom"
    case errSecInvalidAttributeSeed: printString += "errSecInvalidAttributeSeed"
    case errSecMissingAttributeSeed: printString += "errSecMissingAttributeSeed"
    case errSecInvalidAttributePassphrase: printString += "errSecInvalidAttributePassphrase"
    case errSecMissingAttributePassphrase: printString += "errSecMissingAttributePassphrase"
    case errSecInvalidAttributeKeyLength: printString += "errSecInvalidAttributeKeyLength"
    case errSecMissingAttributeKeyLength: printString += "errSecMissingAttributeKeyLength"
    case errSecInvalidAttributeBlockSize: printString += "errSecInvalidAttributeBlockSize"
    case errSecMissingAttributeBlockSize: printString += "errSecMissingAttributeBlockSize"
    case errSecInvalidAttributeOutputSize: printString += "errSecInvalidAttributeOutputSize"
    case errSecMissingAttributeOutputSize: printString += "errSecMissingAttributeOutputSize"
    case errSecInvalidAttributeRounds: printString += "errSecInvalidAttributeRounds"
    case errSecMissingAttributeRounds: printString += "errSecMissingAttributeRounds"
    case errSecInvalidAlgorithmParms: printString += "errSecInvalidAlgorithmParms"
    case errSecMissingAlgorithmParms: printString += "errSecMissingAlgorithmParms"
    case errSecInvalidAttributeLabel: printString += "errSecInvalidAttributeLabel"
    case errSecMissingAttributeLabel: printString += "errSecMissingAttributeLabel"
    case errSecInvalidAttributeKeyType: printString += "errSecInvalidAttributeKeyType"
    case errSecMissingAttributeKeyType: printString += "errSecMissingAttributeKeyType"
    case errSecInvalidAttributeMode: printString += "errSecInvalidAttributeMode"
    case errSecMissingAttributeMode: printString += "errSecMissingAttributeMode"
    case errSecInvalidAttributeEffectiveBits: printString += "errSecInvalidAttributeEffectiveBits"
    case errSecMissingAttributeEffectiveBits: printString += "errSecMissingAttributeEffectiveBits"
    case errSecInvalidAttributeStartDate: printString += "errSecInvalidAttributeStartDate"
    case errSecMissingAttributeStartDate: printString += "errSecMissingAttributeStartDate"
    case errSecInvalidAttributeEndDate: printString += "errSecInvalidAttributeEndDate"
    case errSecMissingAttributeEndDate: printString += "errSecMissingAttributeEndDate"
    case errSecInvalidAttributeVersion: printString += "errSecInvalidAttributeVersion"
    case errSecMissingAttributeVersion: printString += "errSecMissingAttributeVersion"
    case errSecInvalidAttributePrime: printString += "errSecInvalidAttributePrime"
    case errSecMissingAttributePrime: printString += "errSecMissingAttributePrime"
    case errSecInvalidAttributeBase: printString += "errSecInvalidAttributeBase"
    case errSecMissingAttributeBase: printString += "errSecMissingAttributeBase"
    case errSecInvalidAttributeSubprime: printString += "errSecInvalidAttributeSubprime"
    case errSecMissingAttributeSubprime: printString += "errSecMissingAttributeSubprime"
    case errSecInvalidAttributeIterationCount: printString += "errSecInvalidAttributeIterationCount"
    case errSecMissingAttributeIterationCount: printString += "errSecMissingAttributeIterationCount"
    case errSecInvalidAttributeDLDBHandle: printString += "errSecInvalidAttributeDLDBHandle"
    case errSecMissingAttributeDLDBHandle: printString += "errSecMissingAttributeDLDBHandle"
    case errSecInvalidAttributeAccessCredentials: printString += "errSecInvalidAttributeAccessCredentials"
    case errSecMissingAttributeAccessCredentials: printString += "errSecMissingAttributeAccessCredentials"
    case errSecInvalidAttributePublicKeyFormat: printString += "errSecInvalidAttributePublicKeyFormat"
    case errSecMissingAttributePublicKeyFormat: printString += "errSecMissingAttributePublicKeyFormat"
    case errSecInvalidAttributePrivateKeyFormat: printString += "errSecInvalidAttributePrivateKeyFormat"
    case errSecMissingAttributePrivateKeyFormat: printString += "errSecMissingAttributePrivateKeyFormat"
    case errSecInvalidAttributeSymmetricKeyFormat: printString += "errSecInvalidAttributeSymmetricKeyFormat"
    case errSecMissingAttributeSymmetricKeyFormat: printString += "errSecMissingAttributeSymmetricKeyFormat"
    case errSecInvalidAttributeWrappedKeyFormat: printString += "errSecInvalidAttributeWrappedKeyFormat"
    case errSecMissingAttributeWrappedKeyFormat: printString += "errSecMissingAttributeWrappedKeyFormat"
    case errSecStagedOperationInProgress: printString += "errSecStagedOperationInProgress"
    case errSecStagedOperationNotStarted: printString += "errSecStagedOperationNotStarted"
    case errSecVerifyFailed: printString += "errSecVerifyFailed"
    case errSecQuerySizeUnknown: printString += "errSecQuerySizeUnknown"
    case errSecBlockSizeMismatch: printString += "errSecBlockSizeMismatch"
    case errSecPublicKeyInconsistent: printString += "errSecPublicKeyInconsistent"
    case errSecDeviceVerifyFailed: printString += "errSecDeviceVerifyFailed"
    case errSecInvalidLoginName: printString += "errSecInvalidLoginName"
    case errSecAlreadyLoggedIn: printString += "errSecAlreadyLoggedIn"
    case errSecInvalidDigestAlgorithm: printString += "errSecInvalidDigestAlgorithm"
    case errSecInvalidCRLGroup: printString += "errSecInvalidCRLGroup"
    case errSecCertificateCannotOperate: printString += "errSecCertificateCannotOperate"
    case errSecCertificateExpired: printString += "errSecCertificateExpired"
    case errSecCertificateNotValidYet: printString += "errSecCertificateNotValidYet"
    case errSecCertificateRevoked: printString += "errSecCertificateRevoked"
    case errSecCertificateSuspended: printString += "errSecCertificateSuspended"
    case errSecInsufficientCredentials: printString += "errSecInsufficientCredentials"
    case errSecInvalidAction: printString += "errSecInvalidAction"
    case errSecInvalidAuthority: printString += "errSecInvalidAuthority"
    case errSecVerifyActionFailed: printString += "errSecVerifyActionFailed"
    case errSecInvalidCertAuthority: printString += "errSecInvalidCertAuthority"
    case errSecInvalidCRLAuthority: printString += "errSecInvalidCRLAuthority"
    
    case errSecInvalidCRLEncoding: printString += "errSecInvalidCRLEncoding"
    case errSecInvalidCRLType: printString += "errSecInvalidCRLType"
    case errSecInvalidCRL: printString += "errSecInvalidCRL"
    case errSecInvalidFormType: printString += "errSecInvalidFormType"
    case errSecInvalidID: printString += "errSecInvalidID"
    case errSecInvalidIdentifier: printString += "errSecInvalidIdentifier"
    case errSecInvalidIndex: printString += "errSecInvalidIndex"
    case errSecInvalidPolicyIdentifiers: printString += "errSecInvalidPolicyIdentifiers"
    case errSecInvalidTimeString: printString += "errSecInvalidTimeString"
    case errSecInvalidReason: printString += "errSecInvalidReason"
    case errSecInvalidRequestInputs: printString += "errSecInvalidRequestInputs"
    case errSecInvalidResponseVector: printString += "errSecInvalidResponseVector"
    case errSecInvalidStopOnPolicy: printString += "errSecInvalidStopOnPolicy"
    case errSecInvalidTuple: printString += "errSecInvalidTuple"
    case errSecMultipleValuesUnsupported: printString += "errSecMultipleValuesUnsupported"
    case errSecNotTrusted: printString += "errSecNotTrusted"
    case errSecNoDefaultAuthority: printString += "errSecNoDefaultAuthority"
    case errSecRejectedForm: printString += "errSecRejectedForm"
    case errSecRequestLost: printString += "errSecRequestLost"
    case errSecRequestRejected: printString += "errSecRequestRejected"
    case errSecUnsupportedAddressType: printString += "errSecUnsupportedAddressType"
    case errSecUnsupportedService: printString += "errSecUnsupportedService"
    case errSecInvalidTupleGroup: printString += "errSecInvalidTupleGroup"
    case errSecInvalidBaseACLs: printString += "errSecInvalidBaseACLs"
    case errSecInvalidTupleCredentials: printString += "errSecInvalidTupleCredentials"
    
    case errSecInvalidEncoding: printString += "errSecInvalidEncoding"
    case errSecInvalidValidityPeriod: printString += "errSecInvalidValidityPeriod"
    case errSecInvalidRequestor: printString += "errSecInvalidRequestor"
    case errSecRequestDescriptor: printString += "errSecRequestDescriptor"
    case errSecInvalidBundleInfo: printString += "errSecInvalidBundleInfo"
    case errSecInvalidCRLIndex: printString += "errSecInvalidCRLIndex"
    case errSecNoFieldValues: printString += "errSecNoFieldValues"
    case errSecUnsupportedFieldFormat: printString += "errSecUnsupportedFieldFormat"
    case errSecUnsupportedIndexInfo: printString += "errSecUnsupportedIndexInfo"
    case errSecUnsupportedLocality: printString += "errSecUnsupportedLocality"
    case errSecUnsupportedNumAttributes: printString += "errSecUnsupportedNumAttributes"
    case errSecUnsupportedNumIndexes: printString += "errSecUnsupportedNumIndexes"
    case errSecUnsupportedNumRecordTypes: printString += "errSecUnsupportedNumRecordTypes"
    case errSecFieldSpecifiedMultiple: printString += "errSecFieldSpecifiedMultiple"
    case errSecIncompatibleFieldFormat: printString += "errSecIncompatibleFieldFormat"
    case errSecInvalidParsingModule: printString += "errSecInvalidParsingModule"
    case errSecDatabaseLocked: printString += "errSecDatabaseLocked"
    case errSecDatastoreIsOpen: printString += "errSecDatastoreIsOpen"
    case errSecMissingValue: printString += "errSecMissingValue"
    case errSecUnsupportedQueryLimits: printString += "errSecUnsupportedQueryLimits"
    case errSecUnsupportedNumSelectionPreds: printString += "errSecUnsupportedNumSelectionPreds"
    case errSecUnsupportedOperator: printString += "errSecUnsupportedOperator"
    case errSecInvalidDBLocation: printString += "errSecInvalidDBLocation"
    case errSecInvalidAccessRequest: printString += "errSecInvalidAccessRequest"
    case errSecInvalidIndexInfo: printString += "errSecInvalidIndexInfo"
    case errSecInvalidNewOwner: printString += "errSecInvalidNewOwner"
    case errSecInvalidModifyMode: printString += "errSecInvalidModifyMode"
    case errSecMissingRequiredExtension: printString += "errSecMissingRequiredExtension"
    case errSecExtendedKeyUsageNotCritical: printString += "errSecExtendedKeyUsageNotCritical"
    case errSecTimestampMissing: printString += "errSecTimestampMissing"
    case errSecTimestampInvalid: printString += "errSecTimestampInvalid"
    case errSecTimestampNotTrusted: printString += "errSecTimestampNotTrusted"
    case errSecTimestampServiceNotAvailable: printString += "errSecTimestampServiceNotAvailable"
    case errSecTimestampBadAlg: printString += "errSecTimestampBadAlg"
    case errSecTimestampBadRequest: printString += "errSecTimestampBadRequest"
    case errSecTimestampBadDataFormat: printString += "errSecTimestampBadDataFormat"
    case errSecTimestampTimeNotAvailable: printString += "errSecTimestampTimeNotAvailable"
    case errSecTimestampUnacceptedPolicy: printString += "errSecTimestampUnacceptedPolicy"
    case errSecTimestampUnacceptedExtension: printString += "errSecTimestampUnacceptedExtension"
    case errSecTimestampAddInfoNotAvailable: printString += "errSecTimestampAddInfoNotAvailable"
    case errSecTimestampSystemFailure: printString += "errSecTimestampSystemFailure"
    case errSecSigningTimeMissing: printString += "errSecSigningTimeMissing"
    case errSecTimestampRejection: printString += "errSecTimestampRejection"
    case errSecTimestampWaiting: printString += "errSecTimestampWaiting"
    case errSecTimestampRevocationWarning: printString += "errSecTimestampRevocationWarning"
    case errSecTimestampRevocationNotification: printString += "errSecTimestampRevocationNotification"
    case errSecCertificatePolicyNotAllowed: printString += "errSecCertificatePolicyNotAllowed"
    case errSecCertificateNameNotAllowed: printString += "errSecCertificateNameNotAllowed"
    case errSecCertificateValidityPeriodTooLong: printString += "errSecCertificateValidityPeriodTooLong"
    case errSecCertificateIsCA: printString += "errSecCertificateIsCA"
    case errSecCertificateDuplicateExtension: printString += "errSecCertificateDuplicateExtension"

    /*!
     @enum SecureTransport Error Codes
     @abstract Result codes returned from SecureTransport and SecProtocol functions. This is also the domain
       for TLS errors in the network stack.

     @constant errSSLProtocol SSL protocol error
     @constant errSSLNegotiation Cipher Suite negotiation failure
     @constant errSSLFatalAlert Fatal alert
     @constant errSSLWouldBlock I/O would block (not fatal)
     @constant errSSLSessionNotFound attempt to restore an unknown session
     @constant errSSLClosedGraceful connection closed gracefully
     @constant errSSLClosedAbort connection closed via error
     @constant errSSLXCertChainInvalid invalid certificate chain
     @constant errSSLBadCert bad certificate format
     @constant errSSLCrypto underlying cryptographic error
     @constant errSSLInternal Internal error
     @constant errSSLModuleAttach module attach failure
     @constant errSSLUnknownRootCert valid cert chain, untrusted root
     @constant errSSLNoRootCert cert chain not verified by root
     @constant errSSLCertExpired chain had an expired cert
     @constant errSSLCertNotYetValid chain had a cert not yet valid
     @constant errSSLClosedNoNotify server closed session with no notification
     @constant errSSLBufferOverflow insufficient buffer provided
     @constant errSSLBadCipherSuite bad SSLCipherSuite
     @constant errSSLPeerUnexpectedMsg unexpected message received
     @constant errSSLPeerBadRecordMac bad MAC
     @constant errSSLPeerDecryptionFail decryption failed
     @constant errSSLPeerRecordOverflow record overflow
     @constant errSSLPeerDecompressFail decompression failure
     @constant errSSLPeerHandshakeFail handshake failure
     @constant errSSLPeerBadCert misc. bad certificate
     @constant errSSLPeerUnsupportedCert bad unsupported cert format
     @constant errSSLPeerCertRevoked certificate revoked
     @constant errSSLPeerCertExpired certificate expired
     @constant errSSLPeerCertUnknown unknown certificate
     @constant errSSLIllegalParam illegal parameter
     @constant errSSLPeerUnknownCA unknown Cert Authority
     @constant errSSLPeerAccessDenied access denied
     @constant errSSLPeerDecodeError decoding error
     @constant errSSLPeerDecryptError decryption error
     @constant errSSLPeerExportRestriction export restriction
     @constant errSSLPeerProtocolVersion bad protocol version
     @constant errSSLPeerInsufficientSecurity insufficient security
     @constant errSSLPeerInternalError internal error
     @constant errSSLPeerUserCancelled user canceled
     @constant errSSLPeerNoRenegotiation no renegotiation allowed
     @constant errSSLPeerAuthCompleted peer cert is valid, or was ignored if verification disabled
     @constant errSSLClientCertRequested server has requested a client cert
     @constant errSSLHostNameMismatch peer host name mismatch
     @constant errSSLConnectionRefused peer dropped connection before responding
     @constant errSSLDecryptionFail decryption failure
     @constant errSSLBadRecordMac bad MAC
     @constant errSSLRecordOverflow record overflow
     @constant errSSLBadConfiguration configuration error
     @constant errSSLUnexpectedRecord unexpected (skipped) record in DTLS
     @constant errSSLWeakPeerEphemeralDHKey weak ephemeral dh key
     @constant errSSLClientHelloReceived SNI
     @constant errSSLTransportReset transport (socket) shutdown, e.g., TCP RST or FIN.
     @constant errSSLNetworkTimeout network timeout triggered
     @constant errSSLConfigurationFailed TLS configuration failed
     @constant errSSLUnsupportedExtension unsupported TLS extension
     @constant errSSLUnexpectedMessage peer rejected unexpected message
     @constant errSSLDecompressFail decompression failed
     @constant errSSLHandshakeFail handshake failed
     @constant errSSLDecodeError decode failed
     @constant errSSLInappropriateFallback inappropriate fallback
     @constant errSSLMissingExtension missing extension
     @constant errSSLBadCertificateStatusResponse bad OCSP response
     @constant errSSLCertificateRequired certificate required
     @constant errSSLUnknownPSKIdentity unknown PSK identity
     @constant errSSLUnrecognizedName unknown or unrecognized name
     @constant errSSLATSViolation ATS violation
     @constant errSSLATSMinimumVersionViolation ATS violation: minimum protocol version is not ATS compliant
     @constant errSSLATSCiphersuiteViolation ATS violation: selected ciphersuite is not ATS compliant
     @constant errSSLATSMinimumKeySizeViolation ATS violation: peer key size is not ATS compliant
     @constant errSSLATSLeafCertificateHashAlgorithmViolation ATS violation: peer leaf certificate hash algorithm is not ATS compliant
     @constant errSSLATSCertificateHashAlgorithmViolation ATS violation: peer certificate hash algorithm is not ATS compliant
     @constant errSSLATSCertificateTrustViolation ATS violation: peer certificate is not issued by trusted peer
     @constant errSSLEarlyDataRejected Early application data rejected by peer
     */

    /*
     Note: the comments that appear after these errors are used to create SecErrorMessages.strings.
     The comments must not be multi-line, and should be in a form meaningful to an end user. If
     a different or additional comment is needed, it can be put in the header doc format, or on a
     line that does not start with errZZZ.
     */

    case errSSLProtocol: printString += "errSSLProtocol"
    case errSSLNegotiation: printString += "errSSLNegotiation"
    case errSSLFatalAlert: printString += "errSSLFatalAlert"
    case errSSLWouldBlock: printString += "errSSLWouldBlock"
    case errSSLSessionNotFound: printString += "errSSLSessionNotFound"
    case errSSLClosedGraceful: printString += "errSSLClosedGraceful"
    case errSSLClosedAbort: printString += "errSSLClosedAbort"
    case errSSLXCertChainInvalid: printString += "errSSLXCertChainInvalid"
    case errSSLBadCert: printString += "errSSLBadCert"
    case errSSLCrypto: printString += "errSSLCrypto"
    case errSSLInternal: printString += "errSSLInternal"
    case errSSLModuleAttach: printString += "errSSLModuleAttach"
    case errSSLUnknownRootCert: printString += "errSSLUnknownRootCert"
    case errSSLNoRootCert: printString += "errSSLNoRootCert"
    case errSSLCertExpired: printString += "errSSLCertExpired"
    case errSSLCertNotYetValid: printString += "errSSLCertNotYetValid"
    case errSSLClosedNoNotify: printString += "errSSLClosedNoNotify"
    case errSSLBufferOverflow: printString += "errSSLBufferOverflow"
    case errSSLBadCipherSuite: printString += "errSSLBadCipherSuite"

    /* fatal errors detected by peer */
    case errSSLPeerUnexpectedMsg: printString += "errSSLPeerUnexpectedMsg"
    case errSSLPeerBadRecordMac: printString += "errSSLPeerBadRecordMac"
    case errSSLPeerDecryptionFail: printString += "errSSLPeerDecryptionFail"
    case errSSLPeerRecordOverflow: printString += "errSSLPeerRecordOverflow"
    case errSSLPeerDecompressFail: printString += "errSSLPeerDecompressFail"
    case errSSLPeerHandshakeFail: printString += "errSSLPeerHandshakeFail"
    case errSSLPeerBadCert: printString += "errSSLPeerBadCert"
    case errSSLPeerUnsupportedCert: printString += "errSSLPeerUnsupportedCert"
    case errSSLPeerCertRevoked: printString += "errSSLPeerCertRevoked"
    case errSSLPeerCertExpired: printString += "errSSLPeerCertExpired"
    case errSSLPeerCertUnknown: printString += "errSSLPeerCertUnknown"
    case errSSLIllegalParam: printString += "errSSLIllegalParam"
    case errSSLPeerUnknownCA: printString += "errSSLPeerUnknownCA"
    case errSSLPeerAccessDenied: printString += "errSSLPeerAccessDenied"
    case errSSLPeerDecodeError: printString += "errSSLPeerDecodeError"
    case errSSLPeerDecryptError: printString += "errSSLPeerDecryptError"
    case errSSLPeerExportRestriction: printString += "errSSLPeerExportRestriction"
    case errSSLPeerProtocolVersion: printString += "errSSLPeerProtocolVersion"
    case errSSLPeerInsufficientSecurity: printString += "errSSLPeerInsufficientSecurity"
    case errSSLPeerInternalError: printString += "errSSLPeerInternalError"
    case errSSLPeerUserCancelled: printString += "errSSLPeerUserCancelled"
    case errSSLPeerNoRenegotiation: printString += "errSSLPeerNoRenegotiation"

    /* non-fatal result codes */
    case errSSLPeerAuthCompleted: printString += "errSSLPeerAuthCompleted"
    case errSSLClientCertRequested: printString += "errSSLClientCertRequested"

    /* more errors detected by us */
    case errSSLHostNameMismatch: printString += "errSSLHostNameMismatch"
    case errSSLConnectionRefused: printString += "errSSLConnectionRefused"
    case errSSLDecryptionFail: printString += "errSSLDecryptionFail"
    case errSSLBadRecordMac: printString += "errSSLBadRecordMac"
    case errSSLRecordOverflow: printString += "errSSLRecordOverflow"
    case errSSLBadConfiguration: printString += "errSSLBadConfiguration"
    case errSSLUnexpectedRecord: printString += "errSSLUnexpectedRecord"
    case errSSLWeakPeerEphemeralDHKey: printString += "errSSLWeakPeerEphemeralDHKey"

    /* non-fatal result codes */
    case errSSLClientHelloReceived: printString += "errSSLClientHelloReceived"

    /* fatal errors resulting from transport or networking errors */
    case errSSLTransportReset: printString += "errSSLTransportReset"
    case errSSLNetworkTimeout: printString += "errSSLNetworkTimeout"

    /* fatal errors resulting from software misconfiguration */
    case errSSLConfigurationFailed: printString += "errSSLConfigurationFailed"

    /* additional errors */
    case errSSLUnsupportedExtension: printString += "errSSLUnsupportedExtension"
    case errSSLUnexpectedMessage: printString += "errSSLUnexpectedMessage"
    case errSSLDecompressFail: printString += "errSSLDecompressFail"
    case errSSLHandshakeFail: printString += "errSSLHandshakeFail"
    case errSSLDecodeError: printString += "errSSLDecodeError"
    case errSSLInappropriateFallback: printString += "errSSLInappropriateFallback"
    case errSSLMissingExtension: printString += "errSSLMissingExtension"
    case errSSLBadCertificateStatusResponse: printString += "errSSLBadCertificateStatusResponse"
    case errSSLCertificateRequired: printString += "errSSLCertificateRequired"
    case errSSLUnknownPSKIdentity: printString += "errSSLUnknownPSKIdentity"
    case errSSLUnrecognizedName: printString += "errSSLUnrecognizedName"

    /* ATS compliance violation errors */
    case errSSLATSViolation: printString += "errSSLATSViolation"
    case errSSLATSMinimumVersionViolation: printString += "errSSLATSMinimumVersionViolation"
    case errSSLATSCiphersuiteViolation: printString += "errSSLATSCiphersuiteViolation"
    case errSSLATSMinimumKeySizeViolation: printString += "errSSLATSMinimumKeySizeViolation"
    case errSSLATSLeafCertificateHashAlgorithmViolation: printString += "errSSLATSLeafCertificateHashAlgorithmViolation"
    case errSSLATSCertificateHashAlgorithmViolation: printString += "errSSLATSCertificateHashAlgorithmViolation"
    case errSSLATSCertificateTrustViolation: printString += "errSSLATSCertificateTrustViolation"

    /* early data errors */
    case errSSLEarlyDataRejected: printString += "errSSLEarlyDataRejected"
    default:
        fatalError()
    }
    debugPrint("OS Status", printString)
    #endif
}
