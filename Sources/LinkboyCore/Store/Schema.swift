import GRDB

enum Schema {
    static func migrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "entry") { t in
                t.primaryKey("id", .integer)
                t.column("feedID", .integer).notNull()
                t.column("feedTitle", .text).notNull()
                t.column("categoryID", .integer).notNull()
                t.column("categoryTitle", .text).notNull()
                t.column("status", .text).notNull()
                t.column("title", .text).notNull()
                t.column("url", .text).notNull()
                t.column("commentsURL", .text)
                t.column("publishedAt", .double).notNull()
                t.column("changedAt", .double).notNull()
                t.column("starred", .boolean).notNull()
            }
            try db.create(index: "entry_published", on: "entry", columns: ["publishedAt", "id"])
            try db.create(table: "pendingChange") { t in
                t.autoIncrementedPrimaryKey("seq")
                t.column("entryID", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("value", .text).notNull()
                t.uniqueKey(["entryID", "kind"])
            }
            try db.create(table: "meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        return m
    }
}
