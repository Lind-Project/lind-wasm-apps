#ifndef FIX_STD_MAXMIN_H
#define FIX_STD_MAXMIN_H

// Workaround for wasm32 where size_type (unsigned int) and size_t
// (unsigned long) are different C++ types but the same width (32-bit).
// std::min/std::max template deduction fails because it can't unify
// the two types into a single _Tp.  This doesn't happen on x86_64
// where size_t = unsigned long (64-bit) and size_type = size_t.
//
// Fix: provide mixed-type overloads that use std::common_type to
// resolve the return type.  The !is_same<T,U> SFINAE guard ensures
// these only activate when the standard single-type overloads can't
// deduce, avoiding ambiguity.
//
// Force-included via -include before all other headers.

#include <type_traits>

namespace std {

template <typename T, typename U,
          typename = typename enable_if<
              is_arithmetic<T>::value && is_arithmetic<U>::value &&
              !is_same<T, U>::value>::type>
inline constexpr typename common_type<T, U>::type
min(const T& a, const U& b) {
    using CT = typename common_type<T, U>::type;
    return static_cast<CT>(b) < static_cast<CT>(a)
        ? static_cast<CT>(b) : static_cast<CT>(a);
}

template <typename T, typename U,
          typename = typename enable_if<
              is_arithmetic<T>::value && is_arithmetic<U>::value &&
              !is_same<T, U>::value>::type>
inline constexpr typename common_type<T, U>::type
max(const T& a, const U& b) {
    using CT = typename common_type<T, U>::type;
    return static_cast<CT>(a) < static_cast<CT>(b)
        ? static_cast<CT>(b) : static_cast<CT>(a);
}

} // namespace std

#endif // FIX_STD_MAXMIN_H
