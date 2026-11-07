#include <array>
#include <cstdarg>
#include <cstdio>
#include <memory>
#include <new>
#include <ostream>
#include <vector>
#include<chrono>

#include <pans/logger/log_line.h>
#include <pans/utils/system_utils.h>
#include <pans/utils/thread_utils.h>

#include "logger/include/log_buffer.h"
#include "logger/include/log_buffer_config.h"
#include "logger/include/log_logger_impl.h"
#include "logger/include/log_record.h"

namespace pans::detail{
struct LogLine::Impl final{
    Impl(Logger&logger, LogLevel::Level level , std::uint32_t line , std::string_view file_name)
        :m_logger(logger),
        m_level(level),
        m_line(line),
        m_file_name(file_name),
        m_timestamp(std::chrono::system_clock::now()),
        m_elapsed(GetElapsedTime()),
        m_threadId(GetThreadId()),
        m_fiberId(GetFiberId()),
        m_threadName(GetThreadName()),
        m_streamBuffer(m_inlineBuffer),
        m_stream(&m_streamBuffer){}

    /*notes: 

    */
    [[nodiscard]] LogRecordView getRecord()const noexcept{
        // std::cout<<"Log_line.cpp:: getRecord()"<<__LINE__<< "  " <<m_inlineBuffer.view() << std::endl;
        return {
            m_level,
            m_logger.getName(),
            m_inlineBuffer.view(),  // 这里是日志消息的内容
            m_timestamp,
            m_elapsed,
            m_threadId,
            m_fiberId,
            m_threadName,
            m_file_name,
            m_line
        };
    }
// public: 
    Logger& m_logger;
    LogLevel::Level m_level;
    std::uint32_t m_line = 0;
    std::string_view m_file_name;
    std::chrono::system_clock::time_point m_timestamp;
    std::chrono::steady_clock::duration m_elapsed;

    std::uint64_t m_threadId = 0;
    std::uint64_t m_fiberId = 0;

    std::string_view m_threadName;
    InlineBuffer<LOG_MESSAGE_INLINE_CAPACITY>m_inlineBuffer;
    SmallStreamBuffer<LOG_MESSAGE_INLINE_CAPACITY> m_streamBuffer;
    std::ostream m_stream;
};

LogLine::LogLine(Logger&logger, LogLevel::Level level , std::uint32_t line , std::string_view file_name){
    static_assert(sizeof(Impl) <= LOG_LINE_IMPL_SIZE, "LogLine inline implementation storage is too small");
    static_assert(alignof(Impl) <= alignof(std::max_align_t), "LogLine implementation requires excessive alignment");
    std::construct_at(reinterpret_cast<Impl*>(m_implStorage), logger, level, line, file_name);  // 在栈数组上构造对象  // 在特定位置上构造对象  // ？placement new
}

LogLine::Impl& LogLine::getImpl() noexcept{
    return *std::launder(reinterpret_cast<Impl*>(m_implStorage));
    /*notes: 使用 std::launder 确保编译器正确识别指针指向的对象，因为对象是在栈上就地构造的, 是 C++17 引入的函数（<memory>），用于获取指向"新生命周期对象"的正确指针。
        1 为什么这里需要它
            std::construct_at(reinterpret_cast<Impl*>(m_implStorage), ...); 构造时：在原始字节上启动 Impl 的生命周期
            return *std::launder(reinterpret_cast<Impl*>(m_implStorage));   访问时：必须用 launder 告诉编译器"这里有一个新的 Impl 对象"

            m_implStorage 的声明类型是 std::byte[]，编译器知道这块内存"原本"是字节数组。std::construct_at（placement new）在这块内存上启动了 Impl 的新生命周期，但编译器不会自动"知道"这件事。
            如果直接 reinterpret_cast<Impl*>(m_implStorage) 解引用，编译器可能： 基于"这块内存是 std::byte"的假设做优化（比如缓存旧值、消除"冗余"读取）,违反严格别名规则 → 未定义行为（UB）
            std::launder 的作用：告诉编译器"请忘掉这块内存之前的类型，把它当作一个全新的 Impl 对象来对待"，从而：刷新编译器的类型假设,确保后续访问走正确的别名路径, 避免 UB
                UB: 如果通过 m_implStorage 数组名强转去访问里面的 Impl 对象；或者 Impl 类内部包含 const 成员变量、引用成员、或者带有虚函数表指针（vptr），
                    并且在同一块 m_implStorage 内存上发生过“销毁旧对象、重建新对象”的操作；编译器优化器可能会根据严格别名规则（Strict Aliasing）或常量传播假设，
                    认为 m_implStorage 里的数据没有发生变化（或者认为某 const 成员永远等于上一次的值），从而直接复用寄存器里的旧缓存值，导致读出脏数据甚至代码被整个优化删除。
        2   std::launder 是 placement new 的"配套操作"——构造时用 std::construct_at 启动新生命周期，访问时用 std::launder 让编译器承认这个新对象的存在，两者配合才能安全地实现 Fast Pimpl 模式。
    */
}

LogLine::~LogLine(){
    Impl& impl = getImpl();
    LoggerAccess::Submit(impl.m_logger , impl.getRecord()); // 打印日志 // Impl 是 struct  
    std::destroy_at(&impl);  // 显式调用 Impl 的析构函数，因为对象是在栈上就地构造的
}

std::ostream& LogLine::stream() noexcept{
    return getImpl().m_stream; // 返回 Impl 内部的流对象，用于流式日志输出  // 流对象的缓冲区是自己定义的
}

void LogPrintf(Logger& logger , LogLevel::Level level, std::uint32_t line, std::string_view file_name, const char* format, ...){
    //1 在栈上构造 LogLine，其内部通过 Fast Pimpl（placement new）就地构造 Impl
        //Impl 的构造函数会立即采集时间戳、线程 ID、线程名等元数据
        //关键设计：日志的提交（submit）发生在析构时，而非函数体内。这意味着无论函数怎么 return，日志都会被提交
   LogLine log_line(logger, level, line, file_name);
    //2 防御性编程：format 为 null 时写入占位文本
        //return 触发 log_line 析构 → 日志被提交
   if(format == nullptr){
        log_line.stream() << "<null-format>";   //像 LogLine::InLineBuffer 写入
        return ;
   }

   std::array<char , PRINTF_FORMAT_INLINE_CAPACITY> inline_buffer;

   va_list arguments;
   va_list arguments_copy;// 访问可变参数会破坏参数指针偏移量，为了能再次访问可变参数包，必须拷贝一份

   va_start(arguments, format); //va_start(arguments, format) — 初始化参数遍历器，format 是最后一个命名参数，va_start 以此为锚点定位 ... 的起始位置
   //3 必须拷贝，因为：
  
        //// vsnprintf 会使用 va_list，调用后不能再次
        // 使用同一个 va_list 遍历参数。 若需要第二次格式化，必须提前使用 va_copy 保存一份独立的参数遍历状态。
        //第一次 vsnprintf 用 arguments 探测长度后，arguments 已不可复用
        //如果消息超长需要第二次格式化，必须用未消费的 arguments_copy
        //C 标准规定：va_list 被 va_arg 读取后状态未定义，va_copy 是唯一的合法复制方式
   va_copy(arguments_copy, arguments);

   //4  第一次 vsnprintf — 探测长度
        //用栈上固定大小的 inline_buffer 尝试格式化
        //vsnprintf 返回需要的总字节数（不含 \0），即使缓冲区不够也不会溢出
        //如果返回的 required_size 大于 inline_buffer 的大小，说明消息超长，需要第二次格式化
        //大多数日志消息很短，栈上 buffer 一次就够，避免堆分配。
   const int required_size = std::vsnprintf(inline_buffer.data(), inline_buffer.size(), format, arguments);
        /*notes：const int required_size = std::vsnprintf(inline_buffer.data(), inline_buffer.size(), format, arguments);
                                行为                             返回值
                缓冲区足够：	完整写入 + \0	                实际长度（不含 \0）
                缓冲区不够：	只写 size-1 字符 + \0，不溢出	 本应需要的完整长度
                格式串非法：	不写	                        负数
            返回值： 是“需要的长度”，与缓冲区大小无关
            */
   va_end(arguments); //va_end(arguments) — 释放第一个 va_list（已消费完毕）

   if(required_size < 0){  //返回负数表示格式字符串本身有错误  
        va_end(arguments_copy); // va_end(arguments_copy) 是必须的，否则泄漏
        log_line.stream() << "<format-error>";
        return;
    }
   
    const std::size_t message_size = static_cast<std::size_t>(required_size);
    // inline_buffer 大小足够 ， 如果消息长度小于 inline_buffer 的大小，直接使用 inline_buffer 输出，避免堆分配
    if(message_size <  inline_buffer.size()){  // 必须<  , 因为 std::vsnprintf 除了格式化结果，还需要保存一个结尾的 '\0'
        va_end(arguments_copy);
        log_line.stream().write(inline_buffer.data() , static_cast<std::streamsize>(message_size));
        //std::cout<<"LogLine::LogPrintf "<<__LINE__<<" "<< inline_buffer.data()  <<std::endl;
        return ;   
    }


    std::vector<char> overflow_buffer(message_size + 1 );   // +1 给 '\0'
    const int second_result = std::vsnprintf(overflow_buffer.data(), overflow_buffer.size(), format, arguments_copy);
    va_end(arguments_copy);
    if(second_result < 0){
        log_line.stream() << "<format-error>";
        return;
    }
    log_line.stream().write(overflow_buffer.data(), static_cast<std::streamsize>(message_size));
    std::cout<<"LogLine::LogPrintf "<<__LINE__<<" "<< overflow_buffer.data()  <<std::endl;
    // 到这里还只是在内存里格式化这条日志, 出了这个函数，log_line对象析构，才把日志从内存提交到logger的appender中去
}

} // namespace pans::detail

/*notes  
 Fast Pimpl（快速 Pimpl / 栈上就地构造） : 既要用 Pimpl 模式隐藏 Impl 类的头文件依赖，又要彻底消灭 new Impl(...) 带来的堆内存分配（Heap Allocation）开销。

// C++20 标准库实现
std::construct_at: 
    1 在一段已分配但未初始化的内存地址上，直接构造一个对象并启动其生命周期  ,不要求内存一定来自堆
    2 include<memory>
        template<typename _Tp, typename... _Args>
        constexpr T* construct_at(_Tp* __location, _Args&&... __args) //通过完美转发（Perfect Forwarding）传递给 T 构造函数的参数包。
        { 
            return ::new((void*)__location) _Tp(std::forward<_Args>(__args)...); 
        }
    3 本质上就是 placement new( 定位new ) 的语法糖 :
        ::new( (void*)location ) T(args...)
        要求：   调用者提供的内存上构造对象，不分配新内存
                要求内存已经分配好（这里是栈上的 m_implStorage 数组）
                要求内存对齐满足 T 的要求（所以有 alignas(std::max_align_t)）
    4 参数 __location：指向已分配且满足类型 T 对齐要求（alignof(T)）的内存指针。

alignas(std::max_align_t) std::byte m_implStorage[1024];
    1  std::byte：C++17 引入，表示" 一字节原始存储 "，避免 char 的字符语义
    2  alignas(std::max_align_t)：保证对齐 ≥ 平台上任何类型所需的对齐（通常 16 字节），这样任何 Impl 成员（含 double、std::ostream 等）都能安全放置
*/

//  alignas(std::max_align_t) std:: byte m_implStorage[LOG_LINE_IMPL_SIZE];
// std::construct_at(reinterpret_cast<Impl*>(m_implStorage), logger, level, line, file_name);  // 在栈数组上构造对象  // 在特定位置上构造对象  // ？placement new

