import ballerina/crypto;
import ballerina/http;
import ballerina/log;
import ballerina/time;
import ballerinax/mongodb;

final http:Client loremPicsumClient = check new ("https://picsum.photos");
// MongoDB configuration
configurable string host = "localhost";
configurable int port = 27017;
configurable string database = "userDb";

// MongoDB client
final mongodb:Client mongoClient = check new ({
    connection: {
        serverAddress: {
            host: host,
            port: port
        }
    }
});

// User record type for MongoDB
type UserDocument record {
    string email;
    string username;
    string password;
    string? createdAt = ();
    string? lastLogin = ();
    string? authMethod = "local";
    string? googleId = ();
    string? picture = (); // This will store the profile picture URL
    boolean? emailVerified = false;
    string? unsplashImageId = ();
};

// Profile picture update request
type ProfilePictureUpdate record {
    string email;
    string? pictureUrl;
    string? unsplashImageId;
};

// User input type
type UserInput record {
    string email;
    string username;
    string password;
};

// Login request type
type LoginRequest record {
    string email;
    string password;
};

// Enhanced response type with optional data field
type ApiResponse record {
    boolean success;
    string message;
    json? data = ();
};

// UserData record type for MongoDB
type UserDataDocument record {
    string email;
    string username;
    string picture; // Store the profile picture URL
    string? bio = (); // Optional field for user bio
    string? location = (); // Optional field for user location
    string? phoneNumber = (); // Optional field for user phone number
    // Add more fields as needed
};

// CORS configuration
@http:ServiceConfig {
    cors: {
        allowOrigins: ["http://localhost:3000"],
        allowCredentials: false,
        allowHeaders: ["Content-Type"],
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
    }
}

service / on new http:Listener(9090) {

    // Test endpoint for connection verification
    resource function get test() returns json {
        log:printInfo("Test endpoint called");
        return {
            status: "OK",
            message: "Backend is running",
            timestamp: time:utcToString(time:utcNow())
        };
    }

    // Regular signup endpoint - Modified to assign random profile picture
    // Regular signup endpoint - Modified to get real image from API
    resource function post signup(@http:Payload UserInput user) returns ApiResponse|error {
        log:printInfo("=== REGULAR SIGNUP REQUEST ===");
        log:printInfo("Email: " + user.email);
        log:printInfo("Username: " + user.username);

        // Validate input
        if user.email.length() == 0 || user.username.length() == 0 || user.password.length() == 0 {
            log:printWarn("Signup validation failed: Empty fields");
            return {
                success: false,
                message: "All fields are required"
            };
        }

        // Password strength validation
        if user.password.length() < 6 {
            return {
                success: false,
                message: "Password must be at least 6 characters long"
            };
        }

        // Get database and collections
        mongodb:Database userDb = check mongoClient->getDatabase(database);
        mongodb:Collection usersCollection = check userDb->getCollection("users");
        mongodb:Collection userDataCollection = check userDb->getCollection("userData");

        // Check for existing email
        int emailCount = check usersCollection->countDocuments({"email": user.email});
        if emailCount > 0 {
            log:printWarn("Signup failed: Email already exists - " + user.email);
            return {
                success: false,
                message: "Email already exists"
            };
        }

        // Check for existing username
        int usernameCount = check usersCollection->countDocuments({"username": user.username});
        if usernameCount > 0 {
            log:printWarn("Signup failed: Username already exists - " + user.username);
            return {
                success: false,
                message: "Username already exists"
            };
        }

        // Hash password
        byte[] hashedPassword = crypto:hashSha256(user.password.toBytes());
        string hashedPasswordStr = hashedPassword.toBase64();

        // Get current timestamp
        string currentTime = time:utcToString(time:utcNow());

        // Get real profile picture from API
        string|error profilePictureResult = getRealProfilePicture();
        string profilePictureUrl;

        if profilePictureResult is error {
            log:printWarn("Failed to get profile picture from API, using fallback");
            // Fallback to generated URL if API fails
            int randomSeed = time:utcNow()[0];
            profilePictureUrl = "https://picsum.photos/300/300?random=" + randomSeed.toString();
        } else {
            profilePictureUrl = profilePictureResult;
        }

        log:printInfo("Profile picture URL: " + profilePictureUrl);

        // Create new user document
        map<json> newUserDoc = {
            "email": user.email,
            "username": user.username,
            "password": hashedPasswordStr,
            "createdAt": currentTime,
            "lastLogin": (),
            "authMethod": "local",
            "googleId": (),
            "picture": profilePictureUrl,
            "emailVerified": false
        };

        // Insert user into users collection
        mongodb:Error? insertResult = usersCollection->insertOne(newUserDoc);

        if insertResult is mongodb:Error {
            log:printError("Failed to insert user", 'error = insertResult);
            return {
                success: false,
                message: "Failed to create user: " + insertResult.message()
            };
        }

        // Create new userData document with real image URL
        map<json> newUserDataDoc = {
            "email": user.email,
            "username": user.username,
            "picture": profilePictureUrl,  // Store the real image URL
            "bio": (),
            "location": (),
            "phoneNumber": ()
        };

        // Insert userData into userData collection
        mongodb:Error? userDataInsertResult = userDataCollection->insertOne(newUserDataDoc);

        if userDataInsertResult is mongodb:Error {
            log:printError("Failed to insert user data", 'error = userDataInsertResult);

            // Rollback: Delete user from users collection if userData fails
            mongodb:DeleteResult|mongodb:Error rollbackResult = usersCollection->deleteOne({"email": user.email});
            if rollbackResult is mongodb:Error {
                log:printError("Failed to rollback user creation", 'error = rollbackResult);
            }

            return {
                success: false,
                message: "Failed to create user data: " + userDataInsertResult.message()
            };
        }

        log:printInfo("✅ User registered successfully: " + user.username);
        log:printInfo("✅ User profile created in userData collection with real image");

        return {
            success: true,
            message: "User registered successfully",
            data: {
                email: user.email,
                username: user.username,
                authMethod: "local",
                picture: profilePictureUrl
            }
        };
    }

    // Function to get real profile picture from Lorem Picsum API
    function getRealProfilePicture() returns string|error {
        log:printInfo("Fetching real profile picture from Lorem Picsum API");

        try {
        // Generate a random ID for the image (Lorem Picsum has images with IDs 1-1000+)
        int randomId = (time:utcNow()[0] % 1000) + 1;

        // Make request to get image info
        string endpoint = "/" + randomId.toString() + "/info";
        http:Response response = check loremPicsumClient->get(endpoint);

        if response.statusCode == 200 {
            json imageInfo = check response.getJsonPayload();

            // Extract the download URL from the response
            if imageInfo.download_url is string {
                string downloadUrl = <string>imageInfo.download_url;
                log:printInfo("✅ Real image URL obtained: " + downloadUrl);
                return downloadUrl;
            } else {
                log:printWarn("No download_url found in API response");
                return error("No download URL in API response");
            }
        } else {
            log:printWarn("API request failed with status: " + response.statusCode.toString());
            return error("API request failed");
        }
    }

    catch (error e)     {
        log:printError         ("Error fetching real profile picture"         , 'error = e);
return e ;
    }
}
    // Login endpoint - UPDATED to return user data
    // Login endpoint - UPDATED to return user data from userData collection
    resource function post login(@http:Payload LoginRequest credentials) returns ApiResponse|error     {
        log:printInfo         ("=== LOGIN REQUEST ===") ;
        log:printInfo         ("Email: "         + credentials.email );

        // Validate input
if credentials .email .length        () == 0 || credentials .password .length        () == 0          {
            log:printWarn             ("Login validation failed: Empty fields") ;
return {
                success:                 false ,
                                message: "Email and password are required"
                            } ;
        }

        mongodb        :Database userDb= check mongoClient->getDatabase(database);
        mongodb:Collection usersCollection= check userDb->getCollection("users");
        mongodb:Collection userDataCollection= check userDb->getCollection("userData"); // ADD THIS

        // Find user by email
        map<json> filter= {"email": credentials.email};
        mongodb:FindOptions findOptions= {};
        stream<UserDocument, mongodb:Error?> userStream= check usersCollection->find(filter, findOptions);

        UserDocument[] users= check from UserDocument doc in userStream
        select doc;

if users .length        () == 0          {
            log:printWarn             ("Login failed: User not found - "             + credentials.email             ) ;
return {
                success:                 false ,
                                message: "Invalid email or password"
                            } ;
        }

        UserDocument        user = users        [0] ;

        // Verify password
        byte[] hashedPassword= crypto:hashSha256(credentials.password.toBytes());
        string hashedPasswordStr= hashedPassword.toBase64();

if user .password == hashedPasswordStr          {
            log:printInfo             ("✅ Login successful for user: "             + credentials.email );

            // Update last login time
            string currentTime= time:utcToString(time:utcNow());
            mongodb:Update updateDoc= {
            set: {
            "lastLogin": currentTime
            }
            };

            mongodb:UpdateResult|mongodb:Error updateResult= usersCollection->updateOne(filter, updateDoc);
if updateResult is             mongodb:Error              {
                log:printWarn                 ("Failed to update last login time: "                 + updateResult.message                 () );
            }

            // ADD THIS: Get user profile data from userData collection
            stream<UserDataDocument, mongodb:Error?> userDataStream= check userDataCollection->find(filter, findOptions);
            UserDataDocument[] userDataList= check from UserDataDocument doc in userDataStream
            select doc;

            json profileData= {};
if userDataList .length            () > 0 {
            UserDataDocument            userDataDoc = userDataList            [0] ;
            profileData =              {
                picture:userDataDoc .picture,
                    bio:userDataDoc?. bio,
                    location:userDataDoc?. location,
                    phoneNumber:userDataDoc ?.phoneNumber
            } ;
        }

            // Return success with user data including profile
            return          {
            success:             true ,
                        message:             "Login successful" ,
                        data:              {
                email:user .email,
                    username:user. username,
                    loginTime:currentTime,
                    profile:profileData // ADD PROFILE DATA
            }
        } ;
    } else      {
        log:printWarn         ("Login failed: Invalid password for user - "         + credentials.email         ) ;
return {
            success:             false ,
                        message: "Invalid email or password"
                    } ;
    }
}

// Health check endpoint
resource functionget health() returns json {
    time:Utc currentTime = time:utcNow();
    return {
            status: "UP",
            "service": "User Authentication Backend",
            timestamp: time:utcToString(currentTime),
            database: database,
            mongoHost: host + ":" + port.toString()
        };
}

    // Get all users (for testing - remove in production)
    resource 
function getusers() returns ApiResponse|error {
    log:printInfo("Fetching all users");

    mongodb:Database userDb = check mongoClient->getDatabase(database);
    mongodb:Collection usersCollection = check userDb->getCollection("users");

    map<json> filter = {};
    mongodb:FindOptions findOptions = {};
    stream<UserDocument, mongodb:Error?> userStream = check usersCollection->find(filter, findOptions);

    json[] users = check from UserDocument user in userStream
        select {
                email: user.email,
                username: user.username,
                createdAt: user?.createdAt,
                lastLogin: user?.lastLogin
            };

    log:printInfo("Found " + users.length().toString() + " users");

    return {
            success: true,
            message: "Users retrieved successfully",
            data: users
        };
}

    // Delete user endpoint (for testing)
    resource function delete user/[string email]() returns ApiResponse|error     {
        log:printInfo         ("Delete user request for: " + email);

        mongodb:Database userDb= check mongoClient->getDatabase(database);
        mongodb:Collection usersCollection= check userDb->getCollection("users");

        map<json> filter= {"email": email};
        mongodb:DeleteResult|mongodb:Error deleteResult= usersCollection->deleteOne(filter);

if deleteResult is         mongodb:Error          {
            log:printError             ("Failed to delete user"             , 'error = deleteResult            ) ;
return {
                success:                 false ,
                                message: "Failed to delete user"
                            } ;
        }

if deleteResult .deletedCount>         0          {
            log:printInfo             ("✅ User deleted successfully: " + email            ) ;
return {
                success:                 true ,
                                message: "User deleted successfully"
                            } ;
        } else          {
            log:printWarn             ("User not found for deletion: " + email            ) ;
return {
                success:                 false ,
                                message: "User not found"
                            } ;
        }
    }

    // Check if user exists (useful for real-time validation)
    resource function get checkEmail/[string email]() returns ApiResponse|error     {
        mongodb:Database userDb= check mongoClient->getDatabase(database);
        mongodb:Collection usersCollection= check userDb->getCollection("users");

        int count= check usersCollection->countDocuments({"email": email});

return {
            success:             true ,
                        message:count >             0?             "Email exists" : "Email available" ,
                        data:              {
                exists:count                 >                 0
            }
        } ;
    }

    // Get random profile picture from Lorem Picsum
    resource function get randomProfilePicture() returns json|error     {
        string imageUrl= "https://picsum.photos/200/300"; // Change dimensions as needed
return {
            success:             true ,
                        message:             "Random profile picture retrieved" ,
                        data:              {
                url:imageUrl
            }
        } ;
    }

    // Update user profile picture
    resource function put updateProfilePicture(@http:Payload ProfilePictureUpdate updateData) returns ApiResponse|error     {
        log:printInfo         ("Profile picture update request for: "         + updateData.email );

        mongodb:Database userDb= check mongoClient->getDatabase(database);
        mongodb:Collection usersCollection= check userDb->getCollection("users");
        mongodb:Collection userDataCollection= check userDb->getCollection("userData"); // New collection

        // Check if user exists
        int userCount= check usersCollection->countDocuments({"email": updateData.email});
if userCount                   ==         0                   {
        return  {
            success:             false ,
                        message: "User  not found"
                    } ;
    }

    // Prepare update document for users collection
    map<json> updateFields= {
    "picture": updateData.pictureUrl
    };

    mongodb:Update updateDoc= {
    set: updateFields
    };

    // Update user document in users collection
    mongodb:UpdateResult|mongodb:Error updateResult= usersCollection->updateOne({"email": updateData.email}, updateDoc);

if updateResult is     mongodb:Error      {
        log:printError         ("Failed to update profile picture in users collection"         , 'error = updateResult        ) ;
return {
            success:             false ,
                        message: "Failed to update profile picture"
                    } ;
    }

        // Update userData document in userData collection
        mongodb    :UpdateResult|mongodb:Error userDataUpdateResult= userDataCollection->updateOne(
    {"email": updateData.email},
    {set: {"picture": updateData.pictureUrl}}
    );

if userDataUpdateResult is     mongodb:Error      {
        log:printError         ("Failed to update profile picture in userData collection"         , 'error = userDataUpdateResult        ) ;
return {
            success:             false ,
                        message: "Failed to update profile picture in user data"
                    } ;
    }

        log    :printInfo    ("✅ Profile picture updated successfully for: "     + updateData.email     ) ;

return {
        success:         true ,
                message: "Profile picture updated successfully"
            } ;
}

// Get multiple random profile pictures for user to choose from
resource functionget profilePictureOptions / [int count]() returns json|error {
    json[] images = [];

    // Generate multiple random images from Lorem Picsum
    foreach int i in 0 ..< count {
        // Create image object with Lorem Picsum URLs
        json imageData = {
                "id": i.toString(),
                "urls": {
                    "small": "https://picsum.photos/150/150?random=" + i.toString(),
                    "regular": "https://picsum.photos/300/300?random=" + i.toString(),
                    "full": "https://picsum.photos/500/500?random=" + i.toString()
                },
                "user": {
                    "name": "Lorem Picsum"
                }
            };

        images.push(imageData);
    }

    return {
            success: true,
            message: "Profile picture options retrieved",
            data: images
        };
}

    // Get user profile data from userData collection
    resource 
function getuserProfile/[string email]() returns ApiResponse|error {
    log:printInfo("=== GET USER PROFILE REQUEST ===");
    log:printInfo("Email: " + email);

    mongodb:Database userDb = check mongoClient->getDatabase(database);
    mongodb:Collection userDataCollection = check userDb->getCollection("userData");

    // Find user profile by email
    map<json> filter = {"email": email};
    mongodb:FindOptions findOptions = {};
    stream<UserDataDocument, mongodb:Error?> userDataStream = check userDataCollection->find(filter, findOptions);

    UserDataDocument[] userDataList = check from UserDataDocument doc in userDataStream
        select doc;

    if userDataList.length() == 0 {
        log:printWarn("User profile not found: " + email);
        return {
                success: false,
                message: "User profile not found"
            };
    }

    UserDataDocument userDataDoc = userDataList[0];

    return {
            success: true,
            message: "User profile retrieved successfully",
            data: {
                email: userDataDoc.email,
                username: userDataDoc.username,
                picture: userDataDoc.picture,
                bio: userDataDoc?.bio,
                location: userDataDoc?.location,
                phoneNumber: userDataDoc?.phoneNumber
            }
        };
}

    // Update user profile data (bio, location, etc.)
    resource function put updateUserProfile(@http:Payload json profileData) returns ApiResponse|error     {
        log:printInfo         ("=== UPDATE USER PROFILE REQUEST ===") ;

        // Extract email from profile data
        json|error emailValue= profileData.email;
if !(emailValue is string                   )                   {
return  {
            success:             false ,
                        message: "Email is required"
                    } ;
    }

    string email= emailValue;
    log:printInfo     ("Email: " + email);

    mongodb:Database userDb= check mongoClient->getDatabase(database);
    mongodb:Collection userDataCollection= check userDb->getCollection("userData");

    // Check if user exists in userData collection
    int userCount= check userDataCollection->countDocuments({"email": email});
if userCount           ==     0           {
    return  {
        success:         false ,
                message: "User profile not found"
            } ;
}

// Prepare update document
map<json> updateFields = {};

mongodb:Update updateDoc = {
            set: updateFields
        };

// Update userData document
mongodb:UpdateResult|mongodb:Error updateResult = userDataCollection->updateOne(
{"email": email},
updateDoc
);

if updateResult is mongodb:Error {
            log: printError("Failed to update user profile", 'error = updateResult);
return {
                success: false,
                message:  "Failed to update user profile"
            };
}

log:printInfo ( "✅ User profile updated successfully for: " + email) ;

return {
            success: true,
            message:  "User profile updated successfully"
 };
    }

    // Get all userData (for testing - remove in production)
    resourcefunctiongetallUserData()returnsApiResponse|error{
        log:printInfo("Fetching all user data");

        mongodb:DatabaseuserDb=checkmongoClient->getDatabase(database);
        mongodb:CollectionuserDataCollection=checkuserDb->getCollection("userData");

        map<json>filter={};
        mongodb:FindOptionsfindOptions={};
        stream<UserDataDocument,mongodb:Error?>userDataStream=checkuserDataCollection->find(filter,findOptions);

        json[]userData=checkfromUserDataDocumentuserDocinuserDataStream
            select{
                email:userDoc.email,
                username:userDoc.username,
                picture:userDoc.picture,
                bio:userDoc?.bio,
                location:userDoc?.location,
                phoneNumber:userDoc?.phoneNumber
            };

        log:printInfo("Found "+userData.length().toString()+" user profiles");

        return{
            success:true,
            message:"User data retrieved successfully",
            data:userData
        };
    }

    // Delete user profile from userData collection
    resourcefunctiondeleteuserProfile/[stringemail]()returnsApiResponse|error{
        log:printInfo("Delete user profile request for: "+email);

        mongodb:DatabaseuserDb=checkmongoClient->getDatabase(database);
        mongodb:CollectionuserDataCollection=checkuserDb->getCollection("userData");

        map<json>filter={"email":email};
        mongodb:DeleteResult|mongodb:ErrordeleteResult=userDataCollection->deleteOne(filter);

        ifdeleteResultismongodb:Error{
            log:printError("Failed to delete user profile",'error=deleteResult);
            return{
                success:false,
                message:"Failed to delete user profile"
            };
        }

        ifdeleteResult.deletedCount>0{
            log:printInfo("✅ User profile deleted successfully: "+email);
            return{
                success:true,
                message:"User profile deleted successfully"
            };
        }else{
            log:printWarn("User profile not found for deletion: "+email);
            return{
                success:false,
                message:"User profile not found"
            };
        }
    }

    // Check if user profile exists in userData collection
    resourcefunctiongetcheckUserProfile/[stringemail]()returnsApiResponse|error{
        mongodb:DatabaseuserDb=checkmongoClient->getDatabase(database);
        mongodb:CollectionuserDataCollection=checkuserDb->getCollection("userData");

        intcount=checkuserDataCollection->countDocuments({"email":email});

        return{
            success:true,
            message:count>0?"User profile exists":"User profile not found",
            data:{
                exists:count>0,
                email:email
            }
        };
    }

}
