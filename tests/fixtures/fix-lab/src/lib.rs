use std::collections::HashMap;
use std::fmt::Debug;

pub fn total(values: &[i32]) -> i32 {
    let mut sum = 0;
    let unused = 5;
    for v in values {
        sum += v;
    }
    sum
}

pub fn pair(a: i32, b: i32) -> i32 {
    let doubled = a * 2;
    doubled + b
}

pub fn run() -> i32 {
    let mut x = pair(1, 2);
    x
}
