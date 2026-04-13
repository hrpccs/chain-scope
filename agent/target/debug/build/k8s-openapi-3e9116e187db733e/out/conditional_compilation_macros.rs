/// This macro evaluates to its contents if the `v1_18` feature is enabled, otherwise it evaluates to nothing.
///
/// # Examples
///
/// ```rust
/// # #[macro_use] extern crate k8s_openapi;
/// k8s_if_1_18! {
///     use k8s_openapi::api::core::v1 as api;
/// }
/// ```
#[macro_export] macro_rules! k8s_if_1_18 { ($($tt:tt)*) => { }; }

/// This macro evaluates to its contents if the `v1_18` or higher feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_ge_1_18 { ($($tt:tt)*) => { $($tt)* }; }

/// This macro evaluates to its contents if the `v1_18` or lower feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_le_1_18 { ($($tt:tt)*) => { }; }

/// This macro evaluates to its contents if the `v1_19` feature is enabled, otherwise it evaluates to nothing.
///
/// # Examples
///
/// ```rust
/// # #[macro_use] extern crate k8s_openapi;
/// k8s_if_1_19! {
///     use k8s_openapi::api::core::v1 as api;
/// }
/// ```
#[macro_export] macro_rules! k8s_if_1_19 { ($($tt:tt)*) => { }; }

/// This macro evaluates to its contents if the `v1_19` or higher feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_ge_1_19 { ($($tt:tt)*) => { $($tt)* }; }

/// This macro evaluates to its contents if the `v1_19` or lower feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_le_1_19 { ($($tt:tt)*) => { }; }

/// This macro evaluates to its contents if the `v1_20` feature is enabled, otherwise it evaluates to nothing.
///
/// # Examples
///
/// ```rust
/// # #[macro_use] extern crate k8s_openapi;
/// k8s_if_1_20! {
///     use k8s_openapi::api::core::v1 as api;
/// }
/// ```
#[macro_export] macro_rules! k8s_if_1_20 { ($($tt:tt)*) => { }; }

/// This macro evaluates to its contents if the `v1_20` or higher feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_ge_1_20 { ($($tt:tt)*) => { $($tt)* }; }

/// This macro evaluates to its contents if the `v1_20` or lower feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_le_1_20 { ($($tt:tt)*) => { }; }

/// This macro evaluates to its contents if the `v1_21` feature is enabled, otherwise it evaluates to nothing.
///
/// # Examples
///
/// ```rust
/// # #[macro_use] extern crate k8s_openapi;
/// k8s_if_1_21! {
///     use k8s_openapi::api::core::v1 as api;
/// }
/// ```
#[macro_export] macro_rules! k8s_if_1_21 { ($($tt:tt)*) => { }; }

/// This macro evaluates to its contents if the `v1_21` or higher feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_ge_1_21 { ($($tt:tt)*) => { $($tt)* }; }

/// This macro evaluates to its contents if the `v1_21` or lower feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_le_1_21 { ($($tt:tt)*) => { }; }

/// This macro evaluates to its contents if the `v1_22` feature is enabled, otherwise it evaluates to nothing.
///
/// # Examples
///
/// ```rust
/// # #[macro_use] extern crate k8s_openapi;
/// k8s_if_1_22! {
///     use k8s_openapi::api::core::v1 as api;
/// }
/// ```
#[macro_export] macro_rules! k8s_if_1_22 { ($($tt:tt)*) => { }; }

/// This macro evaluates to its contents if the `v1_22` or higher feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_ge_1_22 { ($($tt:tt)*) => { $($tt)* }; }

/// This macro evaluates to its contents if the `v1_22` or lower feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_le_1_22 { ($($tt:tt)*) => { }; }

/// This macro evaluates to its contents if the `v1_23` feature is enabled, otherwise it evaluates to nothing.
///
/// # Examples
///
/// ```rust
/// # #[macro_use] extern crate k8s_openapi;
/// k8s_if_1_23! {
///     use k8s_openapi::api::core::v1 as api;
/// }
/// ```
#[macro_export] macro_rules! k8s_if_1_23 { ($($tt:tt)*) => { }; }

/// This macro evaluates to its contents if the `v1_23` or higher feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_ge_1_23 { ($($tt:tt)*) => { $($tt)* }; }

/// This macro evaluates to its contents if the `v1_23` or lower feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_le_1_23 { ($($tt:tt)*) => { }; }

/// This macro evaluates to its contents if the `v1_24` feature is enabled, otherwise it evaluates to nothing.
///
/// # Examples
///
/// ```rust
/// # #[macro_use] extern crate k8s_openapi;
/// k8s_if_1_24! {
///     use k8s_openapi::api::core::v1 as api;
/// }
/// ```
#[macro_export] macro_rules! k8s_if_1_24 { ($($tt:tt)*) => { }; }

/// This macro evaluates to its contents if the `v1_24` or higher feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_ge_1_24 { ($($tt:tt)*) => { $($tt)* }; }

/// This macro evaluates to its contents if the `v1_24` or lower feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_le_1_24 { ($($tt:tt)*) => { }; }

/// This macro evaluates to its contents if the `v1_25` feature is enabled, otherwise it evaluates to nothing.
///
/// # Examples
///
/// ```rust
/// # #[macro_use] extern crate k8s_openapi;
/// k8s_if_1_25! {
///     use k8s_openapi::api::core::v1 as api;
/// }
/// ```
#[macro_export] macro_rules! k8s_if_1_25 { ($($tt:tt)*) => { $($tt)* }; }

/// This macro evaluates to its contents if the `v1_25` or higher feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_ge_1_25 { ($($tt:tt)*) => { $($tt)* }; }

/// This macro evaluates to its contents if the `v1_25` or lower feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_le_1_25 { ($($tt:tt)*) => { $($tt)* }; }

/// A macro that emits a `match` expr with the given test expression and arms.
/// The match arms can be annotated with the other conditional compilation macros in this crate so that they're only emitted
/// if the predicate is true.
#[macro_export] macro_rules! k8s_match {
    (@inner { $test:expr } { $($arms:tt)* } { }) => {
        match $test { $($arms)* }
    };

    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_1_18!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_ge_1_18!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($arm)*, $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_le_1_18!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($rest)* })
    };

    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_1_19!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_ge_1_19!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($arm)*, $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_le_1_19!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($rest)* })
    };

    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_1_20!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_ge_1_20!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($arm)*, $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_le_1_20!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($rest)* })
    };

    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_1_21!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_ge_1_21!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($arm)*, $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_le_1_21!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($rest)* })
    };

    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_1_22!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_ge_1_22!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($arm)*, $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_le_1_22!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($rest)* })
    };

    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_1_23!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_ge_1_23!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($arm)*, $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_le_1_23!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($rest)* })
    };

    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_1_24!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_ge_1_24!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($arm)*, $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_le_1_24!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($rest)* })
    };

    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_1_25!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($arm)*, $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_ge_1_25!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($arm)*, $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_le_1_25!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($arm)*, $($rest)* })
    };

    (@inner { $test:expr } { $($arms:tt)* } { $next_pat:pat $(if $cond:expr)? => $next_expr:expr, $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* $next_pat $(if $cond)? => $next_expr, } { $($rest)* })
    };

    ($test:expr, { $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { } { $($rest)* })
    };
}
