// Script d'initialisation MongoDB pour LinShare
// NOTE: MONGO_INITDB_ROOT_USERNAME/PASSWORD already creates the 'linshare' user
// as root. This script just sets up the linshare database and collections.

// Switch to the linshare database
db = db.getSiblingDB('linshare');

// Create GridFS collections
db.createCollection('fs.files');
db.createCollection('fs.chunks');

// Create indexes for GridFS (file storage)
db.fs.files.createIndex({ filename: 1 });
db.fs.files.createIndex({ uploadDate: 1 });
db.fs.chunks.createIndex({ files_id: 1, n: 1 }, { unique: true });

print('MongoDB initialized successfully for LinShare');
