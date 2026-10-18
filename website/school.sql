CREATE TABLE "t1_courses" (
  "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  "code" text NOT NULL,
  "teacher" bigint NOT NULL,
  PRIMARY KEY ("id"),
  UNIQUE NULLS NOT DISTINCT ("code")
);

CREATE TABLE "t2_courses_students_items" (
  "id" bigint NOT NULL,
  "value" bigint NOT NULL,
  PRIMARY KEY ("id", "value")
);

CREATE TABLE "t3_people" (
  "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  "email" text NOT NULL,
  "name" text NOT NULL,
  PRIMARY KEY ("id"),
  UNIQUE NULLS NOT DISTINCT ("email")
);

ALTER TABLE "t1_courses" ADD FOREIGN KEY ("teacher") REFERENCES "t3_people" ("id") DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE "t2_courses_students_items" ADD FOREIGN KEY ("id") REFERENCES "t1_courses" ("id") DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE "t2_courses_students_items" ADD FOREIGN KEY ("value") REFERENCES "t3_people" ("id") DEFERRABLE INITIALLY DEFERRED;
