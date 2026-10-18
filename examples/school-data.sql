-- Seed for the exact schema in school.sql; keep in sync with that generated file.
BEGIN;
INSERT INTO "t3_people" ("email", "name") VALUES
  ('alice@example.org', 'Alice'), ('bob@example.org', 'Bob');
INSERT INTO "t1_courses" ("code", "teacher")
  SELECT 'MATH', "id" FROM "t3_people" WHERE "email" = 'alice@example.org';
INSERT INTO "t2_courses_students_items" ("id", "value")
  SELECT c."id", p."id" FROM "t1_courses" c CROSS JOIN "t3_people" p
  WHERE c."code" = 'MATH' AND p."email" = 'bob@example.org';
COMMIT;
