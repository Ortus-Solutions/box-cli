/**
*********************************************************************************
* Copyright Since 2014 CommandBox by Ortus Solutions, Corp
* www.coldbox.org | www.ortussolutions.com
********************************************************************************
* @author Brad Wood, Luis Majano, Denny Valliant
*
* I am the s3 endpoint.
*/
component accessors="true" implements="IEndpoint" singleton {

    // DI
    property name="systemSettings"  inject="SystemSettings";
    property name="fileSystemUtil"  inject="FileSystem";
    property name="httpsEndpoint"   inject="commandbox.system.endpoints.HTTPS";

    // Properties
    property name="namePrefixes" type="string";
    property name="iamRolePath" type="string";

    function init() {
        setNamePrefixes('s3');
        setIamRolePath('169.254.169.254/latest/meta-data/iam/security-credentials/');
        return this;
    }

    public string function resolvePackage(required string package, boolean verbose=false) {
        var bucket = package.listFirst('/');
        var objectKey = package.listRest('/');
        var awsSettings = resolveAwsSettings();
        var presignedPath = generatePresignedPath(bucket, objectKey, awsSettings);
        return httpsEndpoint.resolvePackage(presignedPath, verbose);
    }

    public function getDefaultName(required string package) {
        return httpsEndpoint.getDefaultName(package);
    }

    public function getUpdate(required string package, required string version, boolean verbose=false) {
        return httpsEndpoint.getUpdate(argumentCollection = arguments);
    }

    private function generatePresignedPath(bucket, objectKey, awsSettings) {
        var isoTime = iso8601();
        var bucketRegion = resolveBucketRegion(bucket, awsSettings.defaultRegion);
        var host = 's3.#bucketRegion#.amazonaws.com';
        var path = encodeUrl('/#bucket#/#objectKey#', false);

        // query string
        var qs = {
            'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
            'X-Amz-Credential': awsSettings.awsKey & '/' & isoTime.left( 8 ) & '/' & bucketRegion & '/s3/aws4_request',
            'X-Amz-Date': isoTime,
            'X-Amz-Expires': 300,
            'X-Amz-SignedHeaders': 'host'
        };
        if (awsSettings.sessionToken.len()) {
            qs['X-Amz-Security-Token'] = awsSettings.sessionToken;
        }
        qs = qs.keyArray()
            .sort('text')
            .reduce((r, key) => r.listAppend('#key#=#encodeUrl(qs[key])#', '&'), '');

        // canonical request
        var canonicalRequest = [
            'GET',
            path,
            qs,
            'host:#host#',
            '',
            'host',
            'UNSIGNED-PAYLOAD'
        ].toList(chr(10));

        // string to sign
        var stringtoSign = [
            'AWS4-HMAC-SHA256',
            isoTime,
            isoTime.left( 8 ) & '/' & bucketRegion & '/s3/aws4_request',
            hash(canonicalRequest, 'SHA-256').lcase()
        ].toList(chr(10));

        // signature
        var signingKey = binaryDecode(hmac(isoTime.left(8), 'AWS4' & awsSettings.awsSecretKey, 'hmacSHA256', 'utf-8'), 'hex');
        signingKey = binaryDecode(hmac(bucketRegion, signingKey, 'hmacSHA256', 'utf-8'), 'hex');
        signingKey = binaryDecode(hmac('s3', signingKey, 'hmacSHA256', 'utf-8'), 'hex');
        signingKey = binaryDecode(hmac('aws4_request', signingKey, 'hmacSHA256', 'utf-8'), 'hex');
        var signature = hmac(stringToSign, signingKey, 'hmacSHA256', 'utf-8').lcase();

        qs &= '&X-Amz-Signature=' & signature;
        return '//' & host & path & '?' & qs;
    }

    private function resolveBucketRegion(bucket, defaultRegion) {
        var req = '';
        cfhttp(url='https://s3.#defaultRegion#.amazonaws.com', method='HEAD', result='req', redirect=false) {
            cfhttpparam(type='header', name='Host', value='#bucket#.s3.amazonaws.com');
        }
        return req.responseheader['x-amz-bucket-region'];
    }

    private function resolveAwsSettings() {
        var settings = {
            awsKey: systemSettings.getSystemSetting('AWS_ACCESS_KEY_ID', ''),
            awsSecretKey: systemSettings.getSystemSetting('AWS_SECRET_ACCESS_KEY', ''),
            sessionToken: systemSettings.getSystemSetting('AWS_SESSION_TOKEN', ''),
            defaultRegion: systemSettings.getSystemSetting('AWS_DEFAULT_REGION', ''),
            profile: systemSettings.getSystemSetting('AWS_PROFILE', 'default'),
            configFile: systemSettings.getSystemSetting('AWS_CONFIG_FILE', '~/.aws/config'),
            credentialsFile: systemSettings.getSystemSetting('AWS_SHARED_CREDENTIALS_FILE', '~/.aws/credentials')
        };

        if (!settings.awsKey.len() || !settings.awsSecretKey.len()) {
            var credentials = resolveCredentials(settings.credentialsFile, settings.profile);
            settings.append(credentials);
        }

        if (!settings.defaultRegion.len()) {
            var config = loadSettingsFile(settings.configFile);
            settings.defaultRegion = config[settings.profile].region ?: 'us-east-1';
        }

        return settings;
    }

    private function resolveCredentials(credentialsFile, profile) {
        // check for an aws credentials file for current user
        var credentials = loadSettingsFile(credentialsFile);
        try {
            return {
                awsKey: credentials[profile].aws_access_key_id,
                awsSecretKey: credentials[profile].aws_secret_access_key,
                sessionToken: credentials[profile].aws_session_token ?: ''
            };
        } catch(any e) {
            // pass
        }

        // check for IAM role
        try {
            var req = '';
            cfhttp(url = getIamRolePath(), timeout = 1, result = 'req');
            var roleName = req.filecontent;
            cfhttp(url = getIamRolePath() & roleName, timeout = 1, result = 'req');
            var data = deserializeJSON( req.filecontent );
            return {
                awsKey: data.AccessKeyId,
                awsSecretKey: data.SecretAccessKey,
                sessionToken: data.Token,
                expires: parseDateTime(data.Expiration)
            }
        } catch(any e) {
            // pass
        }

        // Credentials unable to be located
        throw(
            'Could not locate S3 Credentials',
            'endpointException'
        );
    }

    private function loadSettingsFile(settingsFilePath) {
        var settings = {};
        var fullPath = fileSystemUtil.resolvePath(settingsFilePath);
        if (fileExists(fullPath)) {
            var settingLines = fileRead(fullPath).listToArray(chr(10));
            var profile = '';
            for (var line in settingLines) {
                line = line.trim();
                if (reFindNoCase('^\[[a-z]+\]$', line)) {
                    profile = line.mid(2, line.len() - 2);
                } else if (profile.len() && line.len()) {
                    settings[profile][line.listFirst('=').trim()] = line.listRest('=').trim();
                }
            }
        }
        return settings;
    }

    private function iso8601(dateToFormat = now()) {
        return dateTimeFormat(dateToFormat, 'yyyymmdd', 'UTC') & 'T' & dateTimeFormat(dateToFormat, 'HHnnss', 'UTC') & 'Z';
    }

    private function encodeUrl(urlPath, encodeForwardSlash = true) {
        var result = replacelist(urlEncodedFormat(urlPath, 'utf-8'), '%2D,%2E,%5F,%7E', '-,.,_,~');
        if (!encodeForwardSlash) {
            result = result.replace('%2F', '/', 'all');
        }
        return result;
    }

}
