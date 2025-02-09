/*
 * Copyright (c) 2019-2021, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cudf/column/column_view.hpp>
#include <cudf/types.hpp>
#include <cudf/utilities/type_dispatcher.hpp>

#include <cudf_test/base_fixture.hpp>
#include <cudf_test/column_utilities.hpp>
#include <cudf_test/column_wrapper.hpp>
#include <cudf_test/cudf_gtest.hpp>
#include <cudf_test/type_lists.hpp>

#include <thrust/iterator/counting_iterator.h>

#include <random>

template <typename T, typename T2 = void>
struct rep_type_impl {
  using type = void;
};

template <typename T>
struct rep_type_impl<T, std::enable_if_t<cudf::is_timestamp<T>()>> {
  using type = typename T::duration::rep;
};

template <typename T>
struct rep_type_impl<T, std::enable_if_t<cudf::is_duration<T>()>> {
  using type = typename T::rep;
};

template <typename T>
struct rep_type_impl<T, std::enable_if_t<cudf::is_fixed_point<T>()>> {
  using type = typename T::rep;
};

template <typename T>
using rep_type_t = typename rep_type_impl<T>::type;

template <typename T>
struct ColumnViewAllTypesTests : public cudf::test::BaseFixture {
};

TYPED_TEST_SUITE(ColumnViewAllTypesTests, cudf::test::FixedWidthTypes);

template <typename FromType, typename ToType, typename Iterator>
void do_bit_cast(cudf::column_view const& column_view, Iterator begin, Iterator end)
{
  auto mutable_column_view = reinterpret_cast<cudf::mutable_column_view const&>(column_view);
  cudf::data_type to_type{cudf::type_to_id<ToType>()};

  if (std::is_same_v<FromType, ToType>) {
    // Cast to same to_type
    auto output  = cudf::bit_cast(column_view, column_view.type());
    auto output1 = cudf::bit_cast(mutable_column_view, mutable_column_view.type());
    cudf::test::expect_columns_equal(output, column_view);
    cudf::test::expect_columns_equal(output1, mutable_column_view);
  } else if (std::is_same<rep_type_t<FromType>, ToType>::value ||
             std::is_same<FromType, rep_type_t<ToType>>::value) {
    // Cast integer to timestamp or vice versa
    auto output  = cudf::bit_cast(column_view, to_type);
    auto output1 = cudf::bit_cast(mutable_column_view, to_type);
    cudf::test::fixed_width_column_wrapper<ToType, cudf::size_type> expected(begin, end);
    cudf::test::expect_columns_equal(output, expected);
    cudf::test::expect_columns_equal(output1, expected);
  } else {
    if (cuda::std::is_trivially_copyable_v<FromType> &&
        cuda::std::is_trivially_copyable_v<ToType>) {
      constexpr auto from_size = sizeof(cudf::device_storage_type_t<FromType>);
      constexpr auto to_size   = sizeof(cudf::device_storage_type_t<ToType>);
      if (from_size == to_size) {
        // Cast from FromType to ToType
        auto output1         = cudf::bit_cast(column_view, to_type);
        auto output1_mutable = cudf::bit_cast(mutable_column_view, to_type);

        // Cast back from ToType to FromType
        cudf::data_type from_type{cudf::type_to_id<FromType>()};
        auto output2         = cudf::bit_cast(output1, from_type);
        auto output2_mutable = cudf::bit_cast(output1_mutable, from_type);

        cudf::test::expect_columns_equal(output2, column_view);
        cudf::test::expect_columns_equal(output2_mutable, mutable_column_view);
      } else {
        // Not allow to cast if sizes are mismatched
        EXPECT_THROW(cudf::bit_cast(column_view, to_type), cudf::logic_error);
        EXPECT_THROW(cudf::bit_cast(mutable_column_view, to_type), cudf::logic_error);
      }
    } else {
      // Not allow to cast if any of from/to types is not trivially copyable
      EXPECT_THROW(cudf::bit_cast(column_view, to_type), cudf::logic_error);
      EXPECT_THROW(cudf::bit_cast(mutable_column_view, to_type), cudf::logic_error);
    }
  }
}

TYPED_TEST(ColumnViewAllTypesTests, BitCast)
{
  auto begin = thrust::make_counting_iterator(1);
  auto end   = thrust::make_counting_iterator(16);

  cudf::test::fixed_width_column_wrapper<TypeParam, cudf::size_type> input(begin, end);

  do_bit_cast<TypeParam, int8_t>(input, begin, end);
  do_bit_cast<TypeParam, int16_t>(input, begin, end);
  do_bit_cast<TypeParam, int32_t>(input, begin, end);
  do_bit_cast<TypeParam, int64_t>(input, begin, end);
  do_bit_cast<TypeParam, float>(input, begin, end);
  do_bit_cast<TypeParam, double>(input, begin, end);
  do_bit_cast<TypeParam, bool>(input, begin, end);
  do_bit_cast<TypeParam, cudf::duration_D>(input, begin, end);
  do_bit_cast<TypeParam, cudf::duration_s>(input, begin, end);
  do_bit_cast<TypeParam, cudf::duration_ms>(input, begin, end);
  do_bit_cast<TypeParam, cudf::duration_us>(input, begin, end);
  do_bit_cast<TypeParam, cudf::duration_ns>(input, begin, end);
  do_bit_cast<TypeParam, cudf::timestamp_D>(input, begin, end);
  do_bit_cast<TypeParam, cudf::timestamp_s>(input, begin, end);
  do_bit_cast<TypeParam, cudf::timestamp_ms>(input, begin, end);
  do_bit_cast<TypeParam, cudf::timestamp_us>(input, begin, end);
  do_bit_cast<TypeParam, cudf::timestamp_ns>(input, begin, end);
}
