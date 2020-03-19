/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
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

#include <cstdlib>
#include <iostream>
#include <vector>
#include <algorithm>
#include <iterator>
#include <type_traits>

#include <tests/utilities/base_fixture.hpp>
#include <tests/utilities/type_lists.hpp>
//TODO remove after PR 3490 merge
#include <tests/utilities/legacy/cudf_test_utils.cuh>
#include <tests/utilities/column_wrapper.hpp>
#include <tests/utilities/column_utilities.hpp>

#include <cudf/cudf.h>
#include <cudf/reduction.hpp>

#include <thrust/device_vector.h>
#include <thrust/transform_scan.h>

#include <cudf/detail/aggregation/aggregation.hpp>
using aggregation = cudf::experimental::aggregation;
using cudf::experimental::scan_type;
using cudf::include_nulls;
using cudf::column_view;

void print_view(column_view const& view, const char* msg = nullptr) {
    std::cout << msg<< " {";
    cudf::test::print(view); std::cout << "}\n";
}

// This is the main test feature
template <typename T>
struct ScanTest : public cudf::test::BaseFixture
{
    void scan_test(
        cudf::test::fixed_width_column_wrapper<T> const col_in,
        cudf::test::fixed_width_column_wrapper<T> const expected_col_out,
        std::unique_ptr<aggregation> const &agg, scan_type inclusive)
    {
        bool do_print = false;

        auto int_values = cudf::test::to_host<T>(col_in);
        auto exact_values = cudf::test::to_host<T>(expected_col_out);
        this->val_check(std::get<0>(int_values), do_print, "input = ");
        this->val_check(std::get<0>(exact_values), do_print, "exact = ");

        const column_view input_view = col_in;
        std::unique_ptr<cudf::column> col_out;

        CUDF_EXPECT_NO_THROW( col_out = cudf::experimental::scan(input_view, agg, inclusive) );
        const column_view result_view = col_out->view();

        cudf::test::expect_column_properties_equal(input_view, result_view);
        cudf::test::expect_columns_equal(expected_col_out, result_view);

        auto host_result = cudf::test::to_host<T>(result_view);
        this->val_check(std::get<0>(host_result), do_print, "result = ");
    }

    template <typename Ti>
    void val_check(std::vector<Ti> const & v, bool do_print=false, const char* msg = nullptr){
        if( do_print ){
            std::cout << msg << " {";
            std::for_each(v.begin(), v.end(), [](Ti i){ std::cout << ", " <<  i;});
            std::cout << "}"  << std::endl;
        }
        range_check(v);
    }

    // make sure all elements in the range of sint8([-128, 127])
    template <typename Ti>
    void range_check(std::vector<Ti> const & v){
        std::for_each(v.begin(), v.end(),
            [](Ti i){
                ASSERT_GE(static_cast<int>(i), -128);
                ASSERT_LT(static_cast<int>(i),  128);
            });
    }
};

using Types = cudf::test::NumericTypes;

TYPED_TEST_CASE(ScanTest, Types);

// ------------------------------------------------------------------------

template <typename T>
struct value_or {
    T _or;
    explicit value_or(T value) : _or{value} {}
   __host__ __device__ T operator()(thrust::tuple<T, bool> const& tuple) {
       return thrust::get<1>(tuple) ? thrust::get<0>(tuple) : _or;
   }
};

TYPED_TEST(ScanTest, Min)
{
    std::vector<TypeParam> v_std = {123, 64, 63, 99, -5, 123, -16, -120, -111};
    std::vector<bool>      b_std = {  1,  0,  1,  1,  1,   1,   0,    0,    1};
    std::vector<TypeParam> exact(v_std.size());

    thrust::host_vector<TypeParam> v(v_std);
    thrust::host_vector<bool>      b(b_std);

    // TODO: potentially the original author was trying to avoid `thrust::inclusive_scan` for testing
    // if this is the case, I can just replace this with `std::partial_sum` and lambda wrapped `std::min`
    thrust::inclusive_scan(
        v.cbegin(),
        v.cend(),
        exact.begin(),
        thrust::minimum<TypeParam>{});

    this->scan_test({v.begin(), v.end()},
                    {exact.begin(), exact.end()},
                    cudf::experimental::make_min_aggregation(), scan_type::INCLUSIVE);

    auto const first = thrust::make_zip_iterator(thrust::make_tuple(v.begin(), b.begin()));
    auto const last  = thrust::make_zip_iterator(thrust::make_tuple(v.end(),   b.end()));

    // TODO: same as comment above
    thrust::transform_inclusive_scan(
        first,
        last,
        exact.begin(),
        value_or<TypeParam>{std::numeric_limits<TypeParam>::max()},
        thrust::minimum<TypeParam>{});

    this->scan_test({v.begin(), v.end(), b.begin()},
                    {exact.begin(), exact.end(), b.begin()},
                    cudf::experimental::make_min_aggregation(), scan_type::INCLUSIVE);
}

TYPED_TEST(ScanTest, Max)
{
    std::vector<TypeParam> v_std = {-120, 5, 0, -120, -111, 64, 63, 99, 123, -16};
    std::vector<bool>      b_std = {   1, 0, 1,    1,    1,  1,  0,  1,   0,   1};
    std::vector<TypeParam> exact(v_std.size());

    thrust::host_vector<TypeParam> v(v_std);
    thrust::host_vector<bool>      b(b_std);

    thrust::inclusive_scan(
        v.cbegin(),
        v.cend(),
        exact.begin(),
        thrust::maximum<TypeParam>{});

    this->scan_test({v.begin(), v.end()}, 
                    {exact.begin(), exact.end()},
                    cudf::experimental::make_max_aggregation(), scan_type::INCLUSIVE);

    auto const first = thrust::make_zip_iterator(thrust::make_tuple(v.begin(), b.begin()));
    auto const last  = thrust::make_zip_iterator(thrust::make_tuple(v.end(),   b.end()));

    thrust::transform_inclusive_scan(
        first,
        last,
        exact.begin(),
        value_or<TypeParam>{std::numeric_limits<TypeParam>::lowest()},
        thrust::maximum<TypeParam>{});

    this->scan_test({v.begin(), v.end(), b.begin()}, 
                    {exact.begin(), exact.end(), b.begin()},
                    cudf::experimental::make_max_aggregation(), scan_type::INCLUSIVE);
}


TYPED_TEST(ScanTest, Product)
{
    std::vector<TypeParam> v_std = {5, -1, 1, 3, -2, 4};
    std::vector<bool>      b_std = {1,  1, 1, 0,  1, 1};
    std::vector<TypeParam> exact(v_std.size());

    thrust::host_vector<TypeParam> v(v_std);
    thrust::host_vector<bool>      b(b_std);

    thrust::inclusive_scan(
        v.cbegin(),
        v.cend(),
        exact.begin(),
        thrust::multiplies<TypeParam>{});

    this->scan_test({v.begin(), v.end()}, 
                    {exact.begin(), exact.end()},
                    cudf::experimental::make_product_aggregation(), scan_type::INCLUSIVE);

    auto const first = thrust::make_zip_iterator(thrust::make_tuple(v.begin(), b.begin()));
    auto const last  = thrust::make_zip_iterator(thrust::make_tuple(v.end(),   b.end()));

    thrust::transform_inclusive_scan(
        first,
        last,
        exact.begin(),
        value_or<TypeParam>{1},
        thrust::multiplies<TypeParam>{});

    this->scan_test({v.begin(), v.end(), b.begin()}, 
                    {exact.begin(), exact.end(), b.begin()},
                    cudf::experimental::make_product_aggregation(), scan_type::INCLUSIVE);
}

TYPED_TEST(ScanTest, Sum)
{
    std::vector<TypeParam> v_std = {-120, 5, 6, 113, -111, 64, -63, 9, 34, -16};
    std::vector<bool>      b_std = {   1, 0, 1,   1,    0,  0,   1, 1,  1,   1};
    std::vector<TypeParam> exact(v_std.size());

    thrust::host_vector<TypeParam> v(v_std);
    thrust::host_vector<bool>      b(b_std);

    thrust::inclusive_scan(
        v.cbegin(),
        v.cend(),
        exact.begin());

    this->scan_test({v.begin(), v.end()}, 
                    {exact.begin(), exact.end()},
                    cudf::experimental::make_sum_aggregation(), scan_type::INCLUSIVE);

    auto const first = thrust::make_zip_iterator(thrust::make_tuple(v.begin(), b.begin()));
    auto const last  = thrust::make_zip_iterator(thrust::make_tuple(v.end(),   b.end()));

    thrust::transform_inclusive_scan(
        first,
        last,
        exact.begin(),
        value_or<TypeParam>{0},
        thrust::plus<TypeParam>{});

    this->scan_test({v.begin(), v.end(), b.begin()}, 
                    {exact.begin(), exact.end(), b.begin()},
                    cudf::experimental::make_sum_aggregation(), scan_type::INCLUSIVE);
}

struct ScanStringTest : public cudf::test::BaseFixture {
  void scan_test(cudf::test::strings_column_wrapper const& col_in,
                 cudf::test::strings_column_wrapper const& expected_col_out,
                 std::unique_ptr<aggregation> const &agg, scan_type inclusive) 
  {
    bool do_print = false;
    if (do_print) {
      std::cout << "input = {";  cudf::test::print(col_in);  std::cout<<"}\n";
      std::cout << "expect = {";  cudf::test::print(expected_col_out);  std::cout<<"}\n";
    }

    const column_view input_view = col_in;
    std::unique_ptr<cudf::column> col_out;

    CUDF_EXPECT_NO_THROW(col_out = cudf::experimental::scan(input_view, agg, inclusive));
    const column_view result_view = col_out->view();

    cudf::test::expect_column_properties_equal(input_view, result_view);
    cudf::test::expect_columns_equal(expected_col_out, result_view);

    if (do_print) {
      std::cout << "result = {"; cudf::test::print(result_view); std::cout<<"}\n";
    }
  }
};

TEST_F(ScanStringTest, Min)
{
    std::vector<std::string> v_std = {"one", "two", "three", "four", "five", "six", "seven", "eight", "nine"};
    std::vector<bool>        b_std = {    1,     0,       1,      1,      0,     0,       1,       1,      1};
    std::vector<std::string> exact(v_std.size());

    thrust::host_vector<std::string> v(v_std);
    thrust::host_vector<bool>        b(b_std);

    thrust::inclusive_scan(
        v.cbegin(),
        v.cend(),
        exact.begin(),
        thrust::minimum<std::string>{});

    // string column without nulls
    cudf::test::strings_column_wrapper col_nonulls(v.begin(), v.end());
    cudf::test::strings_column_wrapper expected1(exact.begin(), exact.end());
    this->scan_test(col_nonulls, expected1,
                    cudf::experimental::make_min_aggregation(), scan_type::INCLUSIVE);

    // TODO: `std::transform_inclusive_scan` with `std::string` and `thrust::tuple` won't
    //       work due to Thrust bug: https://github.com/thrust/thrust/issues/1074
    //       Update once fix is merged and available
    std::transform(v.cbegin(), v.cend(), b.begin(),
          exact.begin(),
          [acc=v[0]](auto i, bool b) mutable { if(b) acc = std::min(acc, i); return acc; }
          );

    // string column with nulls
    cudf::test::strings_column_wrapper col_nulls(v.begin(), v.end(), b.begin());
    cudf::test::strings_column_wrapper expected2(exact.begin(), exact.end(), b.begin());
    this->scan_test(col_nulls, expected2,
                    cudf::experimental::make_min_aggregation(), scan_type::INCLUSIVE);
}

TEST_F(ScanStringTest, Max)
{
    std::vector<std::string> v_std = {"one", "two", "three", "four", "five", "six", "seven", "eight", "nine"};
    std::vector<bool>        b_std = {    1,     0,       1,      1,      0,     0,       1,       1,      1};
    std::vector<std::string> exact(v_std.size());

    thrust::host_vector<std::string> v(v_std);
    thrust::host_vector<bool>        b(b_std);

    thrust::inclusive_scan(
        v.cbegin(),
        v.cend(),
        exact.begin(),
        thrust::maximum<std::string>{});

    // string column without nulls
    cudf::test::strings_column_wrapper col_nonulls(v.begin(), v.end());
    cudf::test::strings_column_wrapper expected1(exact.begin(), exact.end());
    this->scan_test(col_nonulls, expected1, cudf::experimental::make_max_aggregation(), scan_type::INCLUSIVE);

    // TODO: `std::transform_inclusive_scan` with `std::string` and `thrust::tuple` won't
    //       work due to Thrust bug: https://github.com/thrust/thrust/issues/1074
    //       Update once fix is merged and available
    std::transform(v.cbegin(), v.cend(), b.begin(),
        exact.begin(),
        [acc=v[0]](auto i, bool b) mutable { if(b) acc = std::max(acc, i); return acc; }
        );

    // string column with nulls
    cudf::test::strings_column_wrapper col_nulls(v.begin(), v.end(), b.begin());
    cudf::test::strings_column_wrapper expected2(exact.begin(), exact.end(), b.begin());
    this->scan_test(col_nulls, expected2, cudf::experimental::make_max_aggregation(), scan_type::INCLUSIVE);
}

TYPED_TEST(ScanTest, skip_nulls)
{
    bool do_print=false;
    std::vector<TypeParam> v{1,2,3,4,5,6,7,8,1,1};
    std::vector<bool>      b{1,1,1,1,1,0,1,0,1,1};
    cudf::test::fixed_width_column_wrapper<TypeParam> const col_in{v.begin(), v.end(), b.begin()};
    const column_view input_view = col_in;
    std::unique_ptr<cudf::column> col_out;

    //test output calculation
    std::vector<TypeParam> out_v(input_view.size());
    std::vector<bool>      out_b(input_view.size());

    // TODO: `std::transform_inclusive_scan` with `std::string` and `thrust::tuple` won't
    //       work due to Thrust bug: https://github.com/thrust/thrust/issues/1074
    //       Update once fix is merged and available
    std::transform(
        v.cbegin(),
        v.cend(),
        b.cbegin(),
        out_v.begin(),
        [acc=0](auto i, bool b) mutable { if(b) (acc += i); return acc; });

    thrust::inclusive_scan(
        b.cbegin(),
        b.cend(),
        out_b.begin(),
        thrust::logical_and<bool>{});

    //skipna=true (default)
    CUDF_EXPECT_NO_THROW(col_out = cudf::experimental::scan(input_view,
                        cudf::experimental::make_sum_aggregation(), scan_type::INCLUSIVE, include_nulls::NO));
    cudf::test::fixed_width_column_wrapper<TypeParam> expected_col_out1{
        out_v.begin(), out_v.end(), b.cbegin()};
    cudf::test::expect_column_properties_equal(expected_col_out1, col_out->view());
    cudf::test::expect_columns_equal(expected_col_out1, col_out->view());
    if(do_print) {
        print_view(expected_col_out1, "expect = ");
        print_view(col_out->view(),   "result = ");
    }

    //skipna=false
    CUDF_EXPECT_NO_THROW(col_out = cudf::experimental::scan(input_view,
                        cudf::experimental::make_sum_aggregation(), scan_type::INCLUSIVE, include_nulls::YES));
    cudf::test::fixed_width_column_wrapper<TypeParam> expected_col_out2{
        out_v.begin(), out_v.end(), out_b.begin()};
    if(do_print) {
        print_view(expected_col_out2, "expect = ");
        print_view(col_out->view(),   "result = ");
    }
    cudf::test::expect_column_properties_equal(expected_col_out2, col_out->view());
    cudf::test::expect_columns_equal(expected_col_out2, col_out->view());
}

TEST_F(ScanStringTest, skip_nulls)
{
  bool do_print=false;
  // data and valid arrays
  std::vector<std::string> v({"one", "two", "three", "four", "five", "six", "seven", "eight", "nine"});
  std::vector<bool>        b({    1,     1,       1,      0,      0,     0,       1,       1,      1});
  std::vector<std::string> exact(v.size());
  std::vector<bool>      out_b(v.size());

  // test output calculation
  std::transform(v.cbegin(), v.cend(), b.begin(),
        exact.begin(),
        [acc=v[0]](auto i, bool b) mutable { if(b) acc = std::max(acc, i); return acc; }
        );
  std::transform(b.cbegin(), b.cend(),
      out_b.begin(),
      [acc=true](auto i) mutable { acc = acc && i; return acc; }
      );
  // string column with nulls
  cudf::test::strings_column_wrapper col_nulls(v.begin(), v.end(), b.begin());
  cudf::test::strings_column_wrapper expected2(exact.begin(), exact.end(), out_b.begin());
  std::unique_ptr<cudf::column> col_out;
  //skipna=false
  CUDF_EXPECT_NO_THROW(col_out = cudf::experimental::scan(col_nulls, 
    cudf::experimental::make_max_aggregation(), scan_type::INCLUSIVE, include_nulls::YES));
  if(do_print) {
    print_view(expected2, "expect = ");
    print_view(col_out->view(),   "result = ");
  }
  cudf::test::expect_column_properties_equal(expected2, col_out->view());
  cudf::test::expect_columns_equal(expected2, col_out->view());

  //Exclusive scan string not supported.
  CUDF_EXPECT_THROW_MESSAGE((cudf::experimental::scan(col_nulls, 
  cudf::experimental::make_min_aggregation(), scan_type::EXCLUSIVE, include_nulls::NO)),
  "String types supports only inclusive min/max for `cudf::scan`");

  CUDF_EXPECT_THROW_MESSAGE((cudf::experimental::scan(col_nulls, 
  cudf::experimental::make_min_aggregation(), scan_type::EXCLUSIVE, include_nulls::YES)),
  "String types supports only inclusive min/max for `cudf::scan`");
}

TYPED_TEST(ScanTest, EmptyColumnskip_nulls)
{
  bool do_print=false;
  std::vector<TypeParam> v{};
  std::vector<bool>      b{};
  cudf::test::fixed_width_column_wrapper<TypeParam> const col_in{v.begin(), v.end(),
                                                            b.begin()};
  std::unique_ptr<cudf::column> col_out;
  
  //test output calculation
  std::vector<TypeParam> out_v(v.size());
  std::vector<bool>      out_b(v.size());
  
  //skipna=true (default)
  CUDF_EXPECT_NO_THROW(col_out = cudf::experimental::scan(col_in, 
    cudf::experimental::make_sum_aggregation(), scan_type::INCLUSIVE, include_nulls::NO));
  cudf::test::fixed_width_column_wrapper<TypeParam> expected_col_out1{
      out_v.begin(), out_v.end(), b.cbegin()};
  cudf::test::expect_column_properties_equal(expected_col_out1, col_out->view());
  cudf::test::expect_columns_equal(expected_col_out1, col_out->view());
  if(do_print) {
    print_view(expected_col_out1, "expect = ");
    print_view(col_out->view(),   "result = ");
  }

  //skipna=false
  CUDF_EXPECT_NO_THROW(col_out = cudf::experimental::scan(col_in, 
  cudf::experimental::make_sum_aggregation(), scan_type::INCLUSIVE, include_nulls::YES));
  cudf::test::fixed_width_column_wrapper<TypeParam> expected_col_out2{
      out_v.begin(), out_v.end(), out_b.begin()};
  if(do_print) {
    print_view(expected_col_out2, "expect = ");
    print_view(col_out->view(),   "result = ");
  }
  cudf::test::expect_column_properties_equal(expected_col_out2, col_out->view());
  cudf::test::expect_columns_equal(expected_col_out2, col_out->view());
}