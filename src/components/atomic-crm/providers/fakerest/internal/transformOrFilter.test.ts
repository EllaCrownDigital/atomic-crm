import { transformOrFilter } from "./transformOrFilter";

it("should throw an error if the value is not an object", () => {
  expect(() => transformOrFilter([])).toThrow(
    "Invalid '@or' filter, expected an object",
  );
});

it("should throw an error if the object is empty", () => {
  expect(() => transformOrFilter({})).toThrow(
    "Invalid '@or' filter, object is empty",
  );
});

it("should return the query value", () => {
  expect(transformOrFilter({ "name@ilike": "one" })).toEqual("one");
  expect(
    transformOrFilter({
      "name@ilike": "one",
    }),
  ).toEqual("one");
});
