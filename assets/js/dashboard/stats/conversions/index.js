import React from 'react';
import { Link } from 'react-router-dom'

import Bar from '../bar'
import PropBreakdown from './prop-breakdown'
import numberFormatter from '../../number-formatter'
import * as api from '../../api'
import * as url from '../../url'
import LazyLoader from '../../lazy-loader'

const MOBILE_UPPER_WIDTH = 767
const DEFAULT_WIDTH = 1080

export default class Conversions extends React.Component {
  constructor(props) {
    super(props)
    this.state = {
      loading: true,
      viewport: DEFAULT_WIDTH,
    }
    this.onVisible = this.onVisible.bind(this)

    this.handleResize = this.handleResize.bind(this);
  }

  componentDidMount() {
    window.addEventListener('resize', this.handleResize, false);
    this.handleResize();
  }

  componentWillUnmount() {
    window.removeEventListener('resize', this.handleResize, false);
  }

  handleResize() {
    this.setState({ viewport: window.innerWidth });
  }

  onVisible() {
    this.fetchConversions()
  }

  componentDidUpdate(prevProps) {
    if (this.props.query !== prevProps.query) {
      this.setState({loading: true, goals: null})
      this.fetchConversions()
    }
  }

  getBarMaxWidth() {
    const { viewport } = this.state;
    return viewport > MOBILE_UPPER_WIDTH ? "16rem" : "10rem";
  }

  fetchConversions() {
    api.get(`/api/stats/${encodeURIComponent(this.props.site.domain)}/conversions`, this.props.query)
      .then((res) => this.setState({loading: false, goals: res}))
  }

  renderGoalText(goalName) {
    if (this.props.query.period === 'realtime') {
      return <span className="block px-2 py-1.5 relative z-9 md:truncate break-all dark:text-gray-200">{goalName}</span>
    } else {
      return (
        <Link to={url.setQuery('goal', goalName)} className="block px-2 py-1.5 hover:underline relative z-9 break-all lg:truncate dark:text-gray-200">
          {goalName}
        </Link>
      )
    }
  }



  renderGoal(goal) {
    const { viewport } = this.state;
    const renderProps = this.props.query.filters['goal'] == goal.name && goal.prop_names

    return (
      <div className="my-2 text-sm" key={goal.name}>
        <div className="flex items-center justify-between my-2">
          <Bar
            count={goal.count}
            all={this.state.goals}
            bg="bg-red-50 dark:bg-gray-500 dark:bg-opacity-15"
            maxWidthDeduction={this.getBarMaxWidth()}
          >
            {this.renderGoalText(goal.name)}
          </Bar>
          <div className="dark:text-gray-200">
            <span className="inline-block w-20 font-medium text-right">{numberFormatter(goal.count)}</span>
            {viewport > MOBILE_UPPER_WIDTH && <span className="inline-block w-20 font-medium text-right">{numberFormatter(goal.total_count)}</span>}
            <span className="inline-block w-20 font-medium text-right">{goal.conversion_rate}%</span>
          </div>
        </div>
        { renderProps && <PropBreakdown site={this.props.site} query={this.props.query} goal={goal} /> }
      </div>
    )
  }

  renderInner() {
    const { viewport } = this.state;
    if (this.state.loading) {
      return <div className="mx-auto my-2 loading"><div></div></div>
    } else if (this.state.goals) {
      return (
        <React.Fragment>
          <h3 className="font-bold dark:text-gray-100">{this.props.title || "Goal Conversions"}</h3>
          <div className="flex items-center justify-between mt-3 mb-2 text-xs font-bold tracking-wide text-gray-500 dark:text-gray-400">
            <span>Goal</span>
            <div className="text-right">
              <span className="inline-block w-20">Uniques</span>
              {viewport > MOBILE_UPPER_WIDTH && <span className="inline-block w-20">Total</span>}
              <span className="inline-block w-20">CR</span>
            </div>
          </div>

          { this.state.goals.map(this.renderGoal.bind(this)) }
        </React.Fragment>
      )
    }
  }

  render() {
    return (
      <LazyLoader className="w-full p-4 bg-white rounded shadow-xl dark:bg-gray-825" style={{minHeight: '94px'}} onVisible={this.onVisible}>
        { this.renderInner() }
      </LazyLoader>
    )
  }
}
