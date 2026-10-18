import { exampleOntology, exampleQuery } from "./example";

export type OntologyExample = {
  id: string;
  title: string;
  root: string;
  source: string;
  queries: { title: string; source: string }[];
};

export const ontologyExamples: OntologyExample[] = [
  {
    id: "school", title: "School · students & mentors", root: "Root",
    source: exampleOntology,
    queries: [
      { title: "Students and their mentors", source: exampleQuery },
      { title: "Student count", source: "count(root.students)" },
      { title: "Teachers directory", source: `select teacher.name as name, teacher.email as email
from root.teachers as teacher` },
      { title: "Student subjects", source: `select student.name as name, student.subjects as subjects
from root.students as student` },
    ],
  },
  {
    id: "uber", title: "Uber · riders, drivers & trips", root: "RideHailing",
    source: `// A fictional ride-hailing service with linked riders, drivers and trips.
// Fares are integer cents. Generated values are illustrative test data.

type Location = { city: string; street: string; };
type Rider = { key code: string; name: string; email: string; };
type Vehicle = {
    key plate: string;
    model: string;
    category: "standard" | "comfort" | "xl";
};
type Driver = {
    key code: string;
    name: string;
    vehicle: Ref<Vehicle>;
    available: boolean;
};
type Trip = {
    key code: string;
    rider: Ref<Rider>;
    driver: Ref<Driver>;
    pickup: Location;
    destination: Location;
    status: "requested" | "in_progress" | "completed" | "cancelled";
    fareCents: number;
};
type RideHailing = {
    riders: Rider[];
    vehicles: Vehicle[];
    drivers: Driver[];
    trips: Trip[];
};
`,
    queries: [
      { title: "Trip overview", source: `select trip.code as trip, trip.rider.name as rider,
       trip.driver.name as driver, trip.driver.vehicle.plate as plate,
       trip.pickup.city as pickup, trip.destination.city as destination,
       trip.status as status, trip.fareCents as fareCents
from root.trips as trip` },
      { title: "Completed trips", source: `select trip.code as trip, trip.rider.name as rider,
       trip.fareCents as fareCents
from root.trips as trip
where trip.status = "completed"` },
      { title: "Available drivers and vehicles", source: `select driver.name as driver, driver.vehicle.model as vehicle,
       driver.vehicle.category as category
from root.drivers as driver
where driver.available` },
      { title: "Rider trip histories", source: `select rider.name as rider,
       (select trip.code as trip, trip.status as status
        from root.trips as trip
        where trip.rider = rider) as trips
from root.riders as rider` },
      { title: "Fleet and trip counts", source: `{ riders: count(root.riders), drivers: count(root.drivers),
  vehicles: count(root.vehicles), trips: count(root.trips) }` },
    ],
  },
  {
    id: "shop", title: "Shop · products & orders", root: "Shop",
    source: `type Customer = { key code: string; name: string; email: string; };
type Product = { key sku: string; name: string; priceCents: number; };
type Order = {
    key code: string;
    customer: Ref<Customer>;
    product: Ref<Product>;
    quantity: number;
    status: "pending" | "shipped" | "delivered";
};
type Shop = { customers: Customer[]; products: Product[]; orders: Order[]; };
`,
    queries: [
      { title: "Orders with customer and product", source: `select order.code as order, order.customer.name as customer,
       order.product.name as product, order.quantity as quantity,
       order.status as status
from root.orders as order` },
      { title: "Product catalogue", source: `select product.name as name, product.priceCents as priceCents
from root.products as product` },
      { title: "Pending orders", source: `select order.code as order, order.customer.email as email
from root.orders as order
where order.status = "pending"` },
    ],
  },
  {
    id: "library", title: "Library · books & loans", root: "Library",
    source: `type Author = { key code: string; name: string; };
type Book = { key isbn: string; title: string; author: Ref<Author>; genres: string[]; };
type Member = { key code: string; name: string; email: string; };
type Loan = { key code: string; book: Ref<Book>; member: Ref<Member>; returned: boolean; };
type Library = { authors: Author[]; books: Book[]; members: Member[]; loans: Loan[]; };
`,
    queries: [
      { title: "Books and authors", source: `select book.title as title, book.author.name as author, book.genres as genres
from root.books as book` },
      { title: "Outstanding loans", source: `select loan.book.title as book, loan.member.name as member,
       loan.member.email as email
from root.loans as loan
where not loan.returned` },
      { title: "Member loan counts", source: `select member.name as member,
       count((select loan from root.loans as loan where loan.member = member)) as loans
from root.members as member` },
    ],
  },
];
