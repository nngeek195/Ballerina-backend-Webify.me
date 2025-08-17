import ballerina/crypto;
import ballerina/http;
import ballerina/log;
import ballerina/time;
import ballerinax/mongodb;

// configurable string unsplashAccessKey = "NxAg7G1FeWkcwqrcYNrk6pnoKtnfEbDtK-Mm7FrxLfc";
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

// Unsplash API response type
type UnsplashImage record {
    string id;
    record {
        string small;
        string regular;
        string full;
    } urls;
    record {
        string name;
    } user;
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
    resource function post signup(@http:Payload UserInput user) returns ApiResponse|error {
        log:printInfo("=== REGULAR SIGNUP REQUEST ===");
        log:printInfo("Email: " + user.email);
        log:printInfo("Username: " + user.username);

        // ... existing validation code ...

        // Get database and collection
        mongodb:Database userDb = check mongoClient->getDatabase(database);
        mongodb:Collection usersCollection = check userDb->getCollection("users");

        // ... existing email and username checks ...

        // Hash password
        byte[] hashedPassword = crypto:hashSha256(user.password.toBytes());
        string hashedPasswordStr = hashedPassword.toBase64();

        // Get current timestamp
        string currentTime = time:utcToString(time:utcNow());

        // Generate random profile picture
        int randomSeed = time:utcNow()[0];
        string profilePictureUrl = "https://picsum.photos/300/300?random=" + randomSeed.toString();

        // Create new user document with profile picture
        map<json> newUserDoc = {
            "email": user.email,
            "username": user.username,
            "password": hashedPasswordStr,
            "createdAt": currentTime,
            "lastLogin": (),
            "authMethod": "local",
            "googleId": (),
            "picture": profilePictureUrl,  // Store the profile picture URL
            "pictureId": randomSeed.toString(),  // Store the picture ID for reference
            "emailVerified": false
        };

        // Insert user into database
        mongodb:Error? insertResult = usersCollection->insertOne(newUserDoc);

        if insertResult is mongodb:Error {
            log:printError("Failed to insert user", 'error = insertResult);
            return {
                success: false,
                message: "Failed to create user: " + insertResult.message()
            };
        }

        log:printInfo("✅ User registered successfully: " + user.username);

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

    // Login endpoint - UPDATED to return user data
    resource function post login(@http:Payload LoginRequest credentials) returns ApiResponse|error {
        log:printInfo("=== LOGIN REQUEST ===");
        log:printInfo("Email: " + credentials.email);

        // Validate input
        if credentials.email.length() == 0 || credentials.password.length() == 0 {
            log:printWarn("Login validation failed: Empty fields");
            return {
                success: false,
                message: "Email and password are required"
            };
        }

        mongodb:Database userDb = check mongoClient->getDatabase(database);
        mongodb:Collection usersCollection = check userDb->getCollection("users");

        // Find user by email
        map<json> filter = {"email": credentials.email};
        mongodb:FindOptions findOptions = {};
        stream<UserDocument, mongodb:Error?> userStream = check usersCollection->find(filter, findOptions);

        UserDocument[] users = check from UserDocument doc in userStream
            select doc;

        if users.length() == 0 {
            log:printWarn("Login failed: User not found - " + credentials.email);
            return {
                success: false,
                message: "Invalid email or password"
            };
        }

        UserDocument user = users[0];

        // Verify password
        byte[] hashedPassword = crypto:hashSha256(credentials.password.toBytes());
        string hashedPasswordStr = hashedPassword.toBase64();

        if user.password == hashedPasswordStr {
            log:printInfo("✅ Login successful for user: " + credentials.email);

            // Update last login time
            string currentTime = time:utcToString(time:utcNow());
            mongodb:Update updateDoc = {
                set: {
                    "lastLogin": currentTime
                }
            };

            mongodb:UpdateResult|mongodb:Error updateResult = usersCollection->updateOne(filter, updateDoc);
            if updateResult is mongodb:Error {
                log:printWarn("Failed to update last login time: " + updateResult.message());
            }

            // Return success with user data
            return {
                success: true,
                message: "Login successful",
                data: {
                    email: user.email,
                    username: user.username,
                    loginTime: currentTime
                }
            };
        } else {
            log:printWarn("Login failed: Invalid password for user - " + credentials.email);
            return {
                success: false,
                message: "Invalid email or password"
            };
        }
    }

    // Health check endpoint
    resource function get health() returns json {
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
    resource function get users() returns ApiResponse|error {
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
    resource function delete user/[string email]() returns ApiResponse|error {
        log:printInfo("Delete user request for: " + email);

        mongodb:Database userDb = check mongoClient->getDatabase(database);
        mongodb:Collection usersCollection = check userDb->getCollection("users");

        map<json> filter = {"email": email};
        mongodb:DeleteResult|mongodb:Error deleteResult = usersCollection->deleteOne(filter);

        if deleteResult is mongodb:Error {
            log:printError("Failed to delete user", 'error = deleteResult);
            return {
                success: false,
                message: "Failed to delete user"
            };
        }

        if deleteResult.deletedCount > 0 {
            log:printInfo("✅ User deleted successfully: " + email);
            return {
                success: true,
                message: "User deleted successfully"
            };
        } else {
            log:printWarn("User not found for deletion: " + email);
            return {
                success: false,
                message: "User not found"
            };
        }
    }

    // Check if user exists (useful for real-time validation)
    resource function get checkEmail/[string email]() returns ApiResponse|error {
        mongodb:Database userDb = check mongoClient->getDatabase(database);
        mongodb:Collection usersCollection = check userDb->getCollection("users");

        int count = check usersCollection->countDocuments({"email": email});

        return {
            success: true,
            message: count > 0 ? "Email exists" : "Email available",
            data: {
                exists: count > 0
            }
        };
    }

    // Get random profile picture from Lorem Picsum
    resource function get randomProfilePicture() returns json|error {
        string imageUrl = "https://picsum.photos/200/300"; // Change dimensions as needed
        return {
            success: true,
            message: "Random profile picture retrieved",
            data: {
                url: imageUrl
            }
        };
    }

    // Update user profile picture
    resource function put updateProfilePicture(@http:Payload ProfilePictureUpdate updateData) returns ApiResponse|error {
        log:printInfo("Profile picture update request for: " + updateData.email);

        mongodb:Database userDb = check mongoClient->getDatabase(database);
        mongodb:Collection usersCollection = check userDb->getCollection("users");

        // Check if user exists
        int userCount = check usersCollection->countDocuments({"email": updateData.email});
        if userCount == 0 {
            return {
                success: false,
                message: "User not found"
            };
        }

        // Prepare update document
        map<json> updateFields = {
            "picture": updateData.pictureUrl,
            "unsplashImageId": updateData.unsplashImageId
        };

        mongodb:Update updateDoc = {
            set: updateFields
        };

        mongodb:UpdateResult|mongodb:Error updateResult = usersCollection->updateOne(
            {"email": updateData.email},
            updateDoc
        );

        if updateResult is mongodb:Error {
            log:printError("Failed to update profile picture", 'error = updateResult);
            return {
                success: false,
                message: "Failed to update profile picture"
            };
        }

        log:printInfo("✅ Profile picture updated successfully for: " + updateData.email);

        return {
            success: true,
            message: "Profile picture updated successfully",
            data: {
                pictureUrl: updateData.pictureUrl,
                unsplashImageId: updateData.unsplashImageId
            }
        };
    }

    // Get multiple random profile pictures for user to choose from
    resource function get profilePictureOptions/[int count]() returns json|error {
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
}
