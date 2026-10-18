export const exampleOntology = `// A small world to query.
// Compile to see how these types become tables.

type Address = {
    city: string;
    country: string;
};

type Teacher = {
    key code: string;
    name: string;
    email: string;
};

type Student = {
    key code: string;
    name: string;
    email: string;
    address: Address;
    mentor: Ref<Teacher>;
    subjects: string[];
};

type Root = {
    students: Student[];
    teachers: Teacher[];
};
`;
export const exampleQuery = `select student.name as name,
       student.email as email,
       student.address.city as city,
       student.mentor.name as mentor
from root.students as student`;
